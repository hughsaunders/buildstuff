#!/usr/bin/env python
import collections
import logging
import os
import sys

from cliff.app import App
from cliff.commandmanager import CommandManager
from cliff.command import Command

import chef
import pyrax

log = logging.getLogger(__name__)
log.debug('test log message')

class InstanceManager(object):
    def __init__(self):
        self.action_lists=collections.defaultdict(list)

    def execute(self, action, *args, **kwargs):
       for action in self.action_lists[action]:
           action(*args, **kwargs)


class NovaConnector(object):

    def __init__(self):
        self.cs = pyrax.cloudservers
        self.cnw = pyrax.cloud_networks

    def find_image(self, name):
        images = [img for img in self.cs.images.list() 
                if name.lower in img.name.lower()]
        if images:
            return images[0]
        return []

    def find_network(self, idorname):
        network_list = self.cnw.list()
        for network in network_list:
            if (network.id == idorname or
                    idorname.lower() in network.label.lower()):
                return network
        raise ValueError('No network matching %s found' %idorname)

    def create(self, *args, **kwargs):
        parsed_args = kwargs['parsed_args']
        app=kwargs['app']

        create_kwargs={}
        if network in app.options:
            create_kwargs['nics'] = app.options.network
        self.cs.create(
            parsed_args.name,
            self.find_image(parsed_args.imagename),
            parsed_args.flavorid,
            files = {
                '/root/.ssh/authorized_keys': open(parsed_args.sshpubkey)
            }
            networks[{
                'net-id': 
                }]
        )

    def delete(self):
        for server in pyrax.cloudservers.list():
            if server.name.startswith(self.app.options.prefix):
                log.info('Deleting Nova instance: %s' %server.name)
                server.delete()

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





