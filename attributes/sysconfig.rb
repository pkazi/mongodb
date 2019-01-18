include_attribute 'sc-mongodb::default'

# # mongod defaults
# default['mongodb']['sysconfig']['mongod']['DAEMON'] = '/usr/bin/$NAME'
# default['mongodb']['sysconfig']['mongod']['DAEMON_USER'] = node['mongodb']['user']
# default['mongodb']['sysconfig']['mongod']['DAEMON_OPTS'] = "--config #{node['mongodb']['dbconfig_file']['mongod']}"
# default['mongodb']['sysconfig']['mongod']['CONFIGFILE'] = node['mongodb']['dbconfig_file']['mongod']
# default['mongodb']['sysconfig']['mongod']['ENABLE_MONGODB'] = 'yes'

# # mongos defaults
# default['mongodb']['sysconfig']['mongos']['DAEMON'] = '/usr/bin/$NAME'
# default['mongodb']['sysconfig']['mongos']['DAEMON_USER'] = node['mongodb']['user']
# default['mongodb']['sysconfig']['mongos']['DAEMON_OPTS'] = "--config #{node['mongodb']['dbconfig_file']['mongos']}"
# default['mongodb']['sysconfig']['mongos']['CONFIGFILE'] = node['mongodb']['dbconfig_file']['mongos']
# default['mongodb']['sysconfig']['mongos']['ENABLE_MONGODB'] = 'yes'

# percona mongod defaults
default['mongodb']['sysconfig']['mongod']['OPTIONS'] = "-f #{node['mongodb']['dbconfig_file']['mongod']}"
default['mongodb']['sysconfig']['mongod']['STDOUT'] = '/var/log/mongo/mongod.stdout'
default['mongodb']['sysconfig']['mongod']['STDERR'] = '/var/log/mongo/mongod.stderr'
default['mongodb']['sysconfig']['mongod']['NUMACTL'] = 'numactl --interleave=all'

# percona mongos defaults
default['mongodb']['sysconfig']['mongos']['OPTIONS'] = "-f #{node['mongodb']['dbconfig_file']['mongos']}"
default['mongodb']['sysconfig']['mongos']['STDOUT'] = '/var/log/mongo/mongos.stdout'
default['mongodb']['sysconfig']['mongos']['STDERR'] = '/var/log/mongo/mongos.stderr'
default['mongodb']['sysconfig']['mongos']['NUMACTL'] = 'numactl --interleave=all'
