module MongoDB
  module Helpers
    module Helper
      require 'mongo'
      def get_db_connection(mongo_host, mongo_port, pem_key_file, ca_file)
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
        rescue => e
          Chef::Log.fatal("[get_db_connection] Unable to connect to mongodb, reason : #{e}")
        end
        client
      end

      def authenticate_client(database, username, password)
        # require 'mongo'
        database.authenticate(username, password)
      rescue => e
        Chef::Log.warn("[authenticate_client] Unable to authenticate as #{username} user. reason: #{e}")
        # raise "Unable to authenticate as #{username} user, reason: #{e}"
      end

      def run_command(mongo_host, mongo_port, command, pem_key_file, ca_file, username, password)
        # require 'mongo'
        database = 'admin'
        Chef::Log.info "Running Command #{command} on '#{database}' database of Mongo Instance : #{mongo_host}:#{mongo_port}"
        connection = get_db_connection(mongo_host, mongo_port, pem_key_file, ca_file)
        admin = connection[database]
        authenticate_client(admin, username, password)
        result = admin.command(command, check_response: false)
        Chef::Log.debug("[run_command] #{command} Result : #{result}")
        result
      rescue => e
        Chef::Log.warn("[run_command] Command run #{command} failed on mongo instance.', reason: #{e}")
        {}
        # raise "Command run failed on mongo instance.', reason: #{e}"
      end

      def master_command(mongo_host, mongo_port,pem_key_file, ca_file, username, password)
        cmd = BSON::OrderedHash.new
        cmd['isMaster'] = 1
        run_command(mongo_host, mongo_port, cmd, pem_key_file, ca_file, username, password)
      end

      def primary_node?(mongo_host, mongo_port,pem_key_file, ca_file, username, password)
        result = master_command(mongo_host, mongo_port, pem_key_file, ca_file, username, password)
        result.fetch('ismaster', nil)
      end

      def secondary_node?(mongo_host, mongo_port,pem_key_file, ca_file, username, password)
        result = master_command(mongo_host, mongo_port, pem_key_file, ca_file, username, password)
        result.fetch('secondary', nil)
      end
    end
  end
end

Chef::Recipe.send(:include, MongoDB::Helpers::Helper)
Chef::Resource.send(:include, MongoDB::Helpers::Helper)
