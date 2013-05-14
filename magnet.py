#!/usr/bin/env python
import collections
import logging
import os
import sys
import subprocess

from cliff.app import App
from cliff.commandmanager import CommandManager
from cliff.command import Command

import chef
import pyrax
import spur



log = logging.getLogger(__name__)

class Instance(object):

    def __init__(self, name, app, parsed_args):
        self.app = app
        self.name = name
        self.parsed_args = parsed_args
        self.cs = pyrax.cloudservers
        self.cnw = pyrax.cloud_networks
        self._instance = self.find_instance(self.name)

    def find_instance(self, name):
        for instance in self.cs.list():
            if name.lower() == instance.name.lower():
                return instance

    def check_health(self):
        if self._instance.status == 'ERROR':
            return False
        if self._instance.status in ['BUILDING','SPAWNING']:
            pyrax.utils.wait_until(
                self._instance, 
                'status', 
                ['ACTIVE','ERROR'],
                attempts=60
            )
            if self._instance.status != 'ACTIVE':
                return False
        if not self.ping():
            return False
        return self.ssh_ping()

        
    def ssh_ping(self):
        try:
            result = spur.SshShell(
                    hostname=self._instance.accessIPv4,
                    username='root'
            ).run(['hostname'])
            if (result.return_code == 0 and
                    result.output.strip().split('.')[0] == self.name):
                return True
        except Exception, e:
            log.error('SSH ping for %s/%s failed %s' % (
                self._instance.name,
                self._instance.accessIPv4,
                e
            ))

    def ping(self):
        if not hasattr(self._instance, 'accessIPv4'):
            return False
        return subprocess.Popen(
                ["/usr/bin/env", "ping", "-c1", self._instance.accessIPv4]
        ).wait() == 0

    def find_image(self, idorname):
        for image in self.cs.images.list():
            if (str(image.id) == str(idorname) or
                        idorname.lower() in image.name.lower()):
                return image
        raise ValueError('No image found for %s' %idorname)

    def find_network(self, idorname):
        for network in self.cnw.list():
            if (network.id == idorname or
                    idorname.lower() in network.label.lower()):
                return network
        raise ValueError('No network matching %s found' % idorname)

    def create(self, *args, **kwargs):
        parsed_args = kwargs['parsed_args']

        create_kwargs = {}
        if 'network' in self.app.options:
            create_kwargs['nics'] = self.find_network(self.app.options.network)

        create_kwargs['files'] = {
            '/root/.ssh/authorized_keys': open(parsed_args.sshpubkey)
        }

        self.cs.create(
            parsed_args.name,
            self.find_image(parsed_args.imagename),
            parsed_args.flavorid,
            **create_kwargs
        )

    def delete(self):
        for server in pyrax.cloudservers.list():
            if server.name.startswith(self.app.options.prefix):
                log.info('Deleting Nova instance: %s' %server.name)
                server.delete()

class DNSConnector(object):
    def __init__(self, app):
        self.app = app
        self.domain = pyrax.cloud_dns.find(name=self.options.dnsdomain)

    def create(self, parsed_args):
        name = kwargs['name']
        type = kwargs.get('record_type','A')

        self.domain.add_records([{
            'type': type,
            'name': name,
            'data': data
        }])

class CLIActionDelete(Command):
    def take_action(self,parsed_args):

        # Delete nova instances
        for server in pyrax.cloudservers.list():
            if server.name.startswith(self.app.options.prefix):
                log.info('Deleting Nova instance: %s' %server.name)
                server.delete()

        # Delete DNS records
        if self.app.options.dnsdomain:
                for record in self.app.domain.list_records():
                    if record.name.startswith(self.app.options.prefix):
                        fqdn = '%s.%s' %(server.name,self.app.domain.name)
                        log.info('Removing DNS record: %s' % fqdn)
                        record.delete()

        # Delete Chef Nodes
        for node in chef.Search('node', api=self.app.chef_api):
            if node.object.name.startswith(self.app.options.prefix):
                log.info('Removing chef node: %s' % node.object.name)
                node.object.delete()

        # Delete chef clients. Code structure is dffierent as there is no
        # ApiClient subclass of ChefObject in pychef
        for client in chef.Search('client'):
            name=client['name']
            if name.startswith(self.app.options.prefix):
                log.info('Removing chef client: %s' % name)
                chef.Client(name).delete()

class CLIActionBoot(Command):

    def get_parser(self, prog_name):
        parser = super(CLIActionBoot, self).get_parser(prog_name)
        parser.add_argument('template_name', nargs=1)
        parser.add_argument('--image', nargs=1, default='12.04')
        parser.add_argument('--flavor', nargs=1, default=4)
        parser.add_argument('--network', nargs=1)
        parser.add_argument('--sshpubkey', nargs=1,
                default=os.expanduser('~/.ssh/id_rsa.pub'))
        return parser

    def take_action(self, parsed_args):
        im = InstanceManager()
        im.execute('create', app=self.app, parsed_args=parsed_args)


class ClusterTemplate(object):
    # list of servers required by this template
    servers = []

    # Ordered list of chef client runs required by this template
    chef_client_runs = []



class MagnetApp(App):

    def __init__(self):
        super(MagnetApp, self).__init__(
                description='chef cluster builder',
                version='0.0.1',
                command_manager=SingleModuleCommandManager(__name__)
                )

    def build_option_parser(self, description, version, argparse_kwargs=None):
        parser = super(MagnetApp, self).build_option_parser(description,
                                                            version,
                                                            argparse_kwargs)
        # Global parameters
        parser.add_argument('--prefix',
                            help='Cluster prefix, all instance names will'
                            'be prefix with this string.',
                            default='magnet-')
        parser.add_argument('--pyraxcfg',
                            help='Pyrax configuration file path',
                            default=os.path.expanduser('~/.pyrax.cfg')
                            )
        parser.add_argument('--dnsdomain',
                            help='If specified, instances will be added to '
                            'domain on creation, and removed on deletion. '
                            'Default value is read from environment variable'
                            'MAGNET_DNS_DOMAIN',
                            default=os.environ.get('MAGNET_DNS_DOMAIN',None)
                            )
        return parser

    def initialize_app(self,argv):
        log.debug('Prefix: %s' %self.options.prefix)
        pyrax.set_credential_file(self.options.pyraxcfg)
        self.chef_api = chef.autoconfigure()
        log.debug("chef_api: %s" %self.chef_api)
        if self.options.dnsdomain:
            self.domain = pyrax.cloud_dns.find(name=self.options.dnsdomain)

class SingleModuleCommandManager(CommandManager):
    """CommandManager to load commands from this module, rather than using
    setuptools"""
    def _load_commands(self):
        for obj in globals():
            if str(obj).startswith('CLIAction'):
                self.add_command(str(obj)[9:].lower(),globals()[obj])


def main(argv=sys.argv[1:]):
    magnet = MagnetApp()
    return magnet.run(argv)

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))





