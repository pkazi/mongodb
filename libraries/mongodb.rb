#
# Cookbook Name:: sc-mongodb
# Definition:: mongodb
#
# Copyright 2011, edelight GmbH
# Authors:
#       Markus Korn <markus.korn@edelight.de>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'json'

class Chef::ResourceDefinitionList::MongoDB
  # node['mongodb']['config']['mongod']['net']['port'] required for port
  # if node['mongodb']['use_ip_address']
  #   node['ipaddress'] is required
  # else
  #    node['fqdn'] is required
  # end
  #
  # if node['fqnd'] is a vagrant host, ignore it
  # node['mongodb']['replica_priority'] is required
  #

  def self.node_up?(mongo_host, mongo_port, pem_key_file, ca_file)
    begin
      connection = nil
      rescue_connection_failure do
        # connection = Mongo::Connection.new(mongo_host, mongo_port, op_timeout: 5, slave_ok: true)
        connection = retrieve_db_connection(mongo_host, mongo_port, pem_key_file, ca_file)
        # connection.database_names # check connection
      end
    rescue => e
      Chef::Log.warn("[node_up?] Could not connect to database: '#{mongo_host}:#{mongo_port}', reason: #{e}")
      return false
    end
    true
  end

  def self.get_primary_node(mongo_host, mongo_port, pem_key_file, ca_file, username, password)
    connection = nil
    rescue_connection_failure do
      # connection = Mongo::Connection.new(mongo_host, mongo_port, op_timeout: 5, slave_ok: true)
      connection = retrieve_db_connection(mongo_host, mongo_port, pem_key_file, ca_file)
      # connection.database_names # check connection
      admin = connection['admin']
      authenticate_db(admin, username, password)
      cmd = BSON::OrderedHash.new
      cmd['isMaster'] = 1
      result = admin.command(cmd, check_response: false)
      result.fetch('primary', nil)
    end
  rescue => e
    Chef::Log.warn("[get_primary_node] Could not get the primary node from : '#{mongo_host}:#{mongo_port}', reason: #{e}")
    # return
    raise "Could not get the primary node from : '#{mongo_host}:#{mongo_port}', reason: #{e}"
  end

  def self.cluster_up_to_date?(from_server, expected)
    cut_down = from_server.map do |s|
      other = expected.select { |e| s['_id'] == e['_id'] }.first
      s.select { |k, _v| other.keys.include?(k) } unless other.nil?
    end

    cut_down == expected
  end

  def self.create_replicaset_member(node)
    return {} if node['fqdn'] =~ /\.vagrantup\.com$/

    port = node['mongodb']['config']['mongod']['net']['port']
    host = node['mongodb']['hostname']
    address = "#{host}:#{port}"

    member = {}
    member['host'] = address
    member['arbiterOnly'] = true if node['mongodb']['replica_arbiter_only']
    member['buildIndexes'] = false unless node['mongodb']['replica_build_indexes']
    member['hidden'] = true if node['mongodb']['replica_hidden']
    slave_delay = node['mongodb']['replica_slave_delay']
    member['slaveDelay'] = slave_delay if slave_delay > 0

    priority = if member['buildIndexes'] == false || member['hidden'] || member['slaveDelay']
                 0
               else
                 node['mongodb']['replica_priority']
               end
    member['priority'] = priority unless priority == 1
    tags = node['mongodb']['replica_tags'].to_hash
    member['tags'] = tags unless tags.empty?
    votes = node['mongodb']['replica_votes']
    member['votes'] = votes unless votes == 1

    member.freeze
  end

  def self.retrieve_db_connection(mongo_host, mongo_port, pem_key_file, ca_file)
    require 'mongo'

    begin
      Chef::Log.debug("Connecting to #{mongo_host}:#{mongo_port} with SSL parameters.")
      client = Mongo::MongoClient.new(mongo_host, mongo_port,
                                      ssl: true,
                                      ssl_ca_cert: ca_file,
                                      ssl_cert: pem_key_file,
                                      ssl_key: pem_key_file,
                                      ssl_verify: true,
                                      slave_ok: true,
                                      op_timeout: 5,
                                      connect_timeout: 10
                                     )

      # Query the server for all database names to verify server connection
      # client.database_names
    rescue Mongo::ConnectionFailure => e
      Chef::Log.fatal("[retrieve_db_connection] Unable to connect to mongodb, reason : #{e}")
    end
    client
  end

  def self.authenticate_db(database, username, password)
    require 'mongo'
    database.authenticate(username, password)
  rescue Mongo::AuthenticationError => e
    Chef::Log.warn("Unable to authenticate as #{username} user. If this is a fresh install, ignore warning: #{e}")
    # raise "Unable to authenticate as #{username} user, reason: #{e}"
  end

  def self.configure_replicaset(node, name, members)
    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'
    pem_key_file = node['mongodb']['config']['mongod']['net']['ssl']['PEMKeyFile']
    ca_file = node['mongodb']['config']['mongod']['net']['ssl']['CAFile']
    username = node['mongodb']['authentication']['username']
    password = node['mongodb']['authentication']['password']
    if members.empty? && Chef::Config[:solo]
      Chef::Log.warn('Cannot search for member nodes with chef-solo, defaulting to single node replica set')
    end

    Chef::Log.debug('Removing Self from replica set nodes.')
    members.delete_if { |m| m['mongodb']['hostname'] == node['mongodb']['hostname'] }

    Chef::Log.info("Checking Mongo node availability from chef search resulted nodes :  #{members.map { |n| n['mongodb']['hostname'] }.join(', ')}") unless members.empty?
    members_dup = members.dup
    members_dup.collect do |member|
      mongo_host = member['mongodb']['hostname']
      mongo_port = member['mongodb']['config']['mongod']['net']['port']
      if node_up?(mongo_host, mongo_port, pem_key_file, ca_file)
        Chef::Log.info("Mongo Node [ #{mongo_host}:#{mongo_port} ] is accessible. Nothing to do.")
      else
        Chef::Log.warn("Mongo Node [ #{mongo_host}:#{mongo_port} ] is not accessible. Removing it from chef search results.")
        members.delete_if { |m| m['mongodb']['hostname'] == mongo_host }
      end
    end

    if members.empty?
      Chef::Log.debug("This is the first node from replica set #{name}.")
      mongo_host = 'localhost'
      mongo_port = node['mongodb']['config']['mongod']['net']['port']
    else
      Chef::Log.debug("This is not the first node from replica set #{name}, searching for primary node.")
      remote_host = members.first['mongodb']['hostname']
      remote_port = members.first['mongodb']['config']['mongod']['net']['port']
      primary_node = get_primary_node(remote_host, remote_port, pem_key_file, ca_file, username, password)
      if primary_node.nil?
        Chef::Log.warn("No primary node found for replica set #{name} [ #{mongo_host}:#{mongo_port} ], Please check mongodb instance status.")
        return
      end
      Chef::Log.debug("#{primary_node} is the primary node from replica set #{name}.")
      mongo_host = primary_node.split(':')[0]
      mongo_port = primary_node.split(':')[1]
    end

    # begin
    #   connection = nil
    #   rescue_connection_failure do
    #     connection = Mongo::MongoClient.new(mongo_host, mongo_port, ssl: true, ssl_ca_cert: ca_file, ssl_cert: pem_key_file, ssl_key: pem_key_file, ssl_verify: true, slave_ok: true, connect_timeout: 5, socket_timeout: 5, max_read_retries: 5, server_selection_timeout: 3, op_timeout: 5)
    #     connection.database_names # check connection
    #   end
    # rescue => e
    #   Chef::Log.warn("Could not connect to database: '#{mongo_host}:#{mongo_port}', reason: #{e}")
    #   return
    # end

    connection = retrieve_db_connection(mongo_host, mongo_port, pem_key_file, ca_file)

    # Want the node originating the connection to be included in the replicaset
    members << node unless members.any? { |m| m.name == node.name }
    members.sort! { |x, y| x.name <=> y.name }

    rs_members = members.each_with_index.map { |member, n| create_replicaset_member(member).merge('_id' => n) }.select { |m| m.key? 'host' }

    Chef::Log.info(
      "Configuring replicaset with members #{members.map { |n| n['mongodb']['hostname'] }.join(', ')}"
    )

    Chef::Log.debug(
      "Configuring replicaset with config: #{rs_members}"
    )

    admin = connection['admin']
    # if mongo_host != 'localhost' && node['mongodb']['config']['auth']
    # Chef::Log.debug('Authenticating on admin database since this is not the first node from replicaset.')
    authenticate_db(admin, username, password)
    # end
    cmd = BSON::OrderedHash.new
    cmd['replSetInitiate'] = {
      '_id' => name,
      'members' => rs_members,
    }

    begin
      Chef::Log.debug("Running command : #{cmd}")
      result = admin.command(cmd, check_response: false)
    rescue Mongo::OperationTimeout
      Chef::Log.info('Started configuring the replicaset, this will take some time, another run should run smoothly')
      return
    end
    if result.fetch('ok', nil) == 1
      # everything is fine, do nothing
      Chef::Log.info("Replicaset is initialised successfully : #{result}")
    elsif result.fetch('errmsg', nil) =~ /(\S+) is already initiated/ || \
          result.fetch('errmsg', nil) == 'already initialized' || \
          result.fetch('errmsg', nil) =~ /is not empty on the initiating member/
      Chef::Log.debug("replSetInitiate result is : #{result.fetch('errmsg', nil)}")
      mongo_configured_host, mongo_configured_port = \
        Regexp.last_match.nil? || Regexp.last_match.length < 2 ? [mongo_host, mongo_port] : Regexp.last_match[1].split(':')
      begin
        # connection = Mongo::Connection.new(mongo_configured_host, mongo_configured_port, op_timeout: 5, slave_ok: true)
        connection = retrieve_db_connection(mongo_configured_host, mongo_configured_port, pem_key_file, ca_file)
      rescue
        abort("Could not connect to database: '#{mongo_host}:#{mongo_port}'")
      end

      rs_member_ips =  members.each_with_index.map do |member, n|
        port = member['mongodb']['config']['mongod']['net']['port']
        { '_id' => n, 'host' => "#{member['ipaddress']}:#{port}" }
      end

      admin = connection['admin']
      authenticate_db(admin, username, password) if node['mongodb']['config']['auth']
      # check if both configs are the same
      config = connection['local']['system']['replset'].find_one('_id' => name)
      Chef::Log.debug "Current members are #{config['members']} and we expect #{rs_members}"
      if config && cluster_up_to_date?(config['members'], rs_members)
        # config is up-to-date, do nothing
        Chef::Log.info("Replicaset '#{name}' already configured")
      elsif config['_id'] == name && config['members'] == rs_member_ips
        # config is up-to-date, but ips are used instead of hostnames, change config to hostnames
        Chef::Log.info("Need to convert ips to hostnames for replicaset '#{name}'")
        old_members = config['members'].map { |m| m['host'] }
        mapping = {}
        rs_member_ips.each do |mem_h|
          members.each do |n|
            ip, prt = mem_h['host'].split(':')
            mapping["#{ip}:#{prt}"] = "#{n['mongodb']['hostname']}:#{prt}" if ip == n['ipaddress']
          end
        end
        config['members'].map! do |m|
          host = mapping[m['host']]
          { '_id' => m['_id'], 'host' => host }.merge(rs_options[host])
        end
        config['version'] += 1

        rs_connection = nil
        rescue_connection_failure do
          rs_connection = Mongo::ReplSetConnection.new(old_members)
          rs_connection.database_names # check connection
        end

        admin = rs_connection['admin']
        cmd = BSON::OrderedHash.new
        cmd['replSetReconfig'] = config
        result = nil
        begin
          Chef::Log.debug("Running command : #{cmd}")
          result = admin.command(cmd, check_response: false)
          Chef::Log.info("Replicaset is reconfigured successfully : #{result}") if result.fetch('errmsg', nil).nil?
        rescue Mongo::ConnectionFailure
          # reconfiguring destroys existing connections, reconnect
          # connection = Mongo::Connection.new('localhost', node['mongodb']['config']['port'], op_timeout: 5, slave_ok: true)
          connection = retrieve_db_connection('localhost', mongo_port, pem_key_file, ca_file)
          config = connection['local']['system']['replset'].find_one('_id' => name)
          # Validate configuration change
          if config['members'] == rs_members
            Chef::Log.info("New config successfully applied: #{config.inspect}")
          else
            Chef::Log.error("Failed to apply new config. Current config: #{config.inspect} Target config #{rs_members}")
            return
          end
        end
        Chef::Log.error("configuring replicaset returned: #{result.inspect}") unless result.fetch('errmsg', nil).nil?
      else
        Chef::Log.info 'going to update the members of the replicaset'
        old_members = config['members'].dup
        new_members = rs_members.dup
        old_ids = old_members.map { |m| m['_id'] }

        old_members_by_host = old_members.each_with_object({}) { |m, hash| hash[m['host']] = m  }
        new_members_by_host = new_members.each_with_object({}) { |m, hash| hash[m['host']] = m  }

        ids = (0...256).to_a - old_ids

        # use the _id value when present, use a generated one from ids otherwise
        # new_members = new_members_by_host.map { |h, m| old_members_by_host.fetch(h, {}).merge(m) }
        new_members = new_members_by_host.map { |h, m| old_members_by_host.fetch(h, {}).empty? ? m.merge({ "_id" => old_ids.max+1 }) : m.merge(old_members_by_host.fetch(h, {})) }

        new_members.map! { |member| member.merge('_id' => (member['_id'] || ids.shift)) }

        new_config = config.dup
        new_config['members'] = new_members
        new_config['version'] += 1

        Chef::Log.info "after updating the members, config = #{new_config}"

        rs_connection = nil
        force = false
        rescue_connection_failure do
          case new_members.count
          when 0
            # deletes the replicaset
            force = true
            rs_connection = retrieve_db_connection(mongo_host, mongo_port, pem_key_file, ca_file)
            # rs_connection = Mongo::Connection.new(mongo_host, mongo_port, op_timeout: 5, slave_ok: true)
          else
            rs_connection = retrieve_db_connection(mongo_host, mongo_port, pem_key_file, ca_file)
            # rs_connection = Mongo::ReplSetConnection.new(old_members.map { |m| m['host'] })
          end
          # rs_connection.database_names # check connection
        end

        admin = rs_connection['admin']
        authenticate_db(admin, username, password) if node['mongodb']['config']['auth']
        cmd = BSON::OrderedHash.new
        cmd['replSetReconfig'] = new_config

        result = nil
        begin
          Chef::Log.debug("Running command : #{cmd}")
          result = admin.command(cmd, force: force, check_response: false)
          Chef::Log.info("Replicaset is reconfigured successfully : #{result}") if result.fetch('errmsg', nil).nil?
        rescue Mongo::ConnectionFailure
          # reconfiguring destroys existing connections, reconnect
          connection = retrieve_db_connection(mongo_host, mongo_port, pem_key_file, ca_file)
          # connection = Mongo::Connection.new(mongo_host, mongo_port, op_timeout: 5, slave_ok: true)
          admin = connection['admin']
          authenticate_db(admin, username, password) if node['mongodb']['config']['auth']
          config = connection['local']['system']['replset'].find_one('_id' => name)
          # Validate configuration change
          if config['members'] == rs_members
            Chef::Log.info("New config successfully applied: #{config.inspect}")
          else
            Chef::Log.error("Failed to apply new config. Current config: #{config.inspect} Target config #{rs_members}")
            return
          end
        end
        Chef::Log.error("configuring replicaset returned: #{result.inspect}") unless result.nil? || result.fetch('errmsg', nil).nil?
      end
    elsif !result.fetch('errmsg', nil).nil?
      Chef::Log.error("Failed to configure replicaset, reason: #{result.inspect}")
    end
  end

  def self.configure_shards(node, shard_nodes)
    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'

    shard_groups = Hash.new { |h, k| h[k] = [] }
    pem_key_file = node['mongodb']['config']['mongos']['net']['ssl']['PEMKeyFile']
    ca_file = node['mongodb']['config']['mongos']['net']['ssl']['CAFile']

    Chef::Log.info("Checking Mongo node availability from chef search resulted nodes :  #{shard_nodes.map { |n| n['mongodb']['hostname'] }.join(', ')}")
    shard_nodes.collect do |member|
      mongo_host = member['mongodb']['hostname']
      mongo_port = member['mongodb']['config']['mongod']['net']['port']
      if node_up?(mongo_host, mongo_port, pem_key_file, ca_file)
        Chef::Log.info("Mongo Node [ #{mongo_host}:#{mongo_port} ] is accessible. Nothing to do.")
      else
        Chef::Log.warn("Mongo Node [ #{mongo_host}:#{mongo_port} ] is not accessible. Removing it from chef search results.")
        shard_nodes.delete_if { |m| m['mongodb']['hostname'] == mongo_host }
      end
    end

    shard_nodes.each do |n|
      if n['recipes'].include?('sc-mongodb::replicaset')
        # do not include hidden members when calling addShard
        # see https://jira.mongodb.org/browse/SERVER-9882
        next if n['mongodb']['replica_hidden']
        key = n['mongodb']['config']['mongod']['replication']['replSetName'] || "rs_#{n['mongodb']['shard_name']}"
      else
        key = '_single'
      end
      shard_groups[key] << "#{n['mongodb']['hostname']}:#{n['mongodb']['config']['mongod']['net']['port']}"
    end
    Chef::Log.info(shard_groups.inspect)

    shard_members = []
    shard_groups.each do |name, members|
      if name == '_single'
        shard_members += members
      else
        shard_members << "#{name}/#{members.join(',')}"
      end
    end
    Chef::Log.info(shard_members.inspect)

    mongo_port = node['mongodb']['config']['mongos']['net']['port']

    begin
      connection = nil
      rescue_connection_failure do
        connection = retrieve_db_connection('localhost', mongo_port, pem_key_file, ca_file)
        # connection = Mongo::Connection.new('localhost', mongo_port, op_timeout: 5)
      end
    rescue => e
      Chef::Log.warn("Could not connect to database: 'localhost:#{mongo_port}', reason #{e}")
      return
    end

    admin = connection['admin']
    authenticate_db(admin, node['mongodb']['authentication']['username'], node['mongodb']['authentication']['password']) if node['mongodb']['config']['auth']
    # # If we require authentication on mongos / mongod, need to authenticate to run these commands
    # if node.recipe?('sc-mongodb::user_management')
    #   begin
    #     admin.authenticate(node['mongodb']['authentication']['username'], node['mongodb']['authentication']['password'])
    #   rescue Mongo::AuthenticationError => e
    #     Chef::Log.warn("Unable to authenticate with database to add shards to mongos node: #{e}")
    #   end
    # end

    shard_members.each do |shard|
      cmd = BSON::OrderedHash.new
      cmd['addShard'] = shard
      require 'pry'
      # binding.pry
      begin
        Chef::Log.debug("Running command : #{cmd}")
        result = admin.command(cmd, check_response: false)
      rescue Mongo::OperationTimeout
        result = "Adding shard '#{shard}' timed out, run the recipe again to check the result"
      end

      if result['ok'] == 0.0
        Chef::Log.error(result.inspect)
      else
        Chef::Log.info(result.inspect)
      end
    end
  end

  def self.configure_sharded_collections(node, sharded_collections)
    if sharded_collections.nil? || sharded_collections.empty?
      Chef::Log.warn('No sharded collections configured, doing nothing')
      return
    end

    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'

    mongo_port = node['mongodb']['config']['mongos']['net']['port']
    pem_key_file = node['mongodb']['config']['mongos']['net']['ssl']['PEMKeyFile']
    ca_file = node['mongodb']['config']['mongos']['net']['ssl']['CAFile']

    begin
      connection = nil
      rescue_connection_failure do
        connection = retrieve_db_connection('localhost', mongo_port, pem_key_file, ca_file)
        # connection = Mongo::Connection.new('localhost', mongo_port, op_timeout: 5)
      end
    rescue => e
      Chef::Log.warn("Could not connect to database: 'localhost:#{mongo_port}', reason #{e}")
      return
    end

    admin = connection['admin']
    authenticate_db(admin, node['mongodb']['authentication']['username'], node['mongodb']['authentication']['password']) if node['mongodb']['config']['auth']
    # # If we require authentication on mongos / mongod, need to authenticate to run these commands
    # if node.recipe?('sc-mongodb::user_management')
    #   begin
    #     admin.authenticate(node['mongodb']['authentication']['username'], node['mongodb']['authentication']['password'])
    #   rescue Mongo::AuthenticationError => e
    #     Chef::Log.warn("Unable to authenticate with database to configure databased on mongos node: #{e}")
    #   end
    # end

    databases = sharded_collections.keys.map { |x| x.split('.').first }.uniq
    Chef::Log.info("enable sharding for these databases: '#{databases.inspect}'")

    databases.each do |db_name|
      cmd = BSON::OrderedHash.new
      cmd['enablesharding'] = db_name
      begin
        Chef::Log.debug("Running command : #{cmd}")
        result = admin.command(cmd, check_response: false)
      rescue Mongo::OperationTimeout
        result = "enable sharding for '#{db_name}' timed out, run the recipe again to check the result"
      end
      if result['ok'] == 0
        # some error
        errmsg = result.fetch('errmsg')
        if errmsg == 'already enabled'
          Chef::Log.info("Sharding is already enabled for database '#{db_name}', doing nothing")
        else
          Chef::Log.error("Failed to enable sharding for database #{db_name}, result was: #{result.inspect}")
        end
      else
        # success
        Chef::Log.info("Enabled sharding for database '#{db_name}'")
      end
    end

    sharded_collections.each do |name, key|
      cmd = BSON::OrderedHash.new
      cmd['shardcollection'] = name
      cmd['key'] = { key => 1 }
      begin
        Chef::Log.debug("Running command : #{cmd}")
        result = admin.command(cmd, check_response: false)
      rescue Mongo::OperationTimeout
        result = "sharding '#{name}' on key '#{key}' timed out, run the recipe again to check the result"
      end
      if result['ok'] == 0
        # some error
        errmsg = result.fetch('errmsg')
        if errmsg == 'already sharded'
          Chef::Log.info("Sharding is already configured for collection '#{name}', doing nothing")
        else
          Chef::Log.error("Failed to shard collection #{name}, result was: #{result.inspect}")
        end
      else
        # success
        Chef::Log.info("Sharding for collection '#{result['collectionsharded']}' enabled")
      end
    end
  end

  # Ensure retry upon failure
  def self.rescue_connection_failure(max_retries = 30)
    retries = 0
    begin
      yield
    rescue Mongo::ConnectionFailure => ex
      retries += 1
      raise ex if retries > max_retries
      sleep(0.5)
      retry
    end
  end
end
