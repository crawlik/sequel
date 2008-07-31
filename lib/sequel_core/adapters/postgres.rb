require 'sequel_core/adapters/shared/postgres'

begin 
  require 'pg' 
  SEQUEL_POSTGRES_USES_PG = true
rescue LoadError => e 
  SEQUEL_POSTGRES_USES_PG = false
  begin
    require 'postgres'
    # Attempt to get uniform behavior for the PGconn object no matter
    # if pg, postgres, or postgres-pr is used.
    class PGconn
      unless method_defined?(:escape_string)
        if self.respond_to?(:escape)
          # If there is no escape_string instead method, but there is an
          # escape class method, use that instead.
          def escape_string(str)
            self.class.escape(str)
          end
        else
          # Raise an error if no valid string escaping method can be found.
          def escape_string(obj)
            raise Sequel::Error, "string escaping not supported with this postgres driver.  Try using ruby-pg, ruby-postgres, or postgres-pr."
          end
        end
      end
      unless method_defined?(:escape_bytea)
        if self.respond_to?(:escape_bytea)
          # If there is no escape_bytea instance method, but there is an
          # escape_bytea class method, use that instead.
          def escape_bytea(obj)
            self.class.escape_bytea(obj)
          end
        else
          begin
            require 'postgres-pr/typeconv/conv'
            require 'postgres-pr/typeconv/bytea'
            extend Postgres::Conversion
            # If we are using postgres-pr, use the encode_bytea method from
            # that.
            def escape_bytea(obj)
              self.class.encode_bytea(obj)
            end
            metaalias :unescape_bytea, :decode_bytea
          rescue
            # If no valid bytea escaping method can be found, create one that
            # raises an error
            def escape_bytea(obj)
              raise Sequel::Error, "bytea escaping not supported with this postgres driver.  Try using ruby-pg, ruby-postgres, or postgres-pr."
            end
            # If no valid bytea unescaping method can be found, create one that
            # raises an error
            def self.unescape_bytea(obj)
              raise Sequel::Error, "bytea unescaping not supported with this postgres driver.  Try using ruby-pg, ruby-postgres, or postgres-pr."
            end
          end
        end
      end
      alias_method :finish, :close unless method_defined?(:finish) 
    end
    class PGresult 
      alias_method :nfields, :num_fields unless method_defined?(:nfields) 
      alias_method :ntuples, :num_tuples unless method_defined?(:ntuples) 
      alias_method :ftype, :type unless method_defined?(:ftype) 
      alias_method :fname, :fieldname unless method_defined?(:fname) 
      alias_method :cmd_tuples, :cmdtuples unless method_defined?(:cmd_tuples) 
    end 
  rescue LoadError 
    raise e 
  end 
end

module Sequel
  # Top level module for holding all PostgreSQL-related modules and classes
  # for Sequel.
  module Postgres
    CONVERTED_EXCEPTIONS << PGError
    
    # Hash with integer keys and proc values for converting PostgreSQL types.
    PG_TYPES = {
      16 => lambda{ |s| Postgres.string_to_bool(s) }, # boolean
      17 => lambda{ |s| Adapter.unescape_bytea(s).to_blob }, # bytea
      20 => lambda{ |s| s.to_i }, # int8
      21 => lambda{ |s| s.to_i }, # int2
      22 => lambda{ |s| s.to_i }, # int2vector
      23 => lambda{ |s| s.to_i }, # int4
      26 => lambda{ |s| s.to_i }, # oid
      700 => lambda{ |s| s.to_f }, # float4
      701 => lambda{ |s| s.to_f }, # float8
      790 => lambda{ |s| s.to_d }, # money
      1082 => lambda{ |s| s.to_date }, # date
      1083 => lambda{ |s| s.to_time }, # time without time zone
      1114 => lambda{ |s| s.to_sequel_time }, # timestamp without time zone
      1184 => lambda{ |s| s.to_sequel_time }, # timestamp with time zone
      1186 => lambda{ |s| s.to_i }, # interval
      1266 => lambda{ |s| s.to_time }, # time with time zone
      1700 => lambda{ |s| s.to_d }, # numeric
    }
    
    # Module method for converting a PostgreSQL string to a boolean value.
    def self.string_to_bool(s)
      if(s.blank?)
        nil
      elsif(s.downcase == 't' || s.downcase == 'true')
        true
      else
        false
      end
    end
    
    # PGconn subclass for connection specific methods used with the
    # pg, postgres, or postgres-pr driver.
    class Adapter < ::PGconn
      include Sequel::Postgres::AdapterMethods
      self.translate_results = false if respond_to?(:translate_results=)
      
      # Execute the given SQL with this connection.  If a block is given,
      # yield the results, otherwise, return the number of changed rows.
      def execute(sql, *args)
        q = nil
        begin
          q = exec(sql, *args)
        rescue PGError => e
          raise if status == Adapter::CONNECTION_OK
          reset
          q = exec(sql, *args)
        end
        begin
          block_given? ? yield(q) : q.cmd_tuples
        ensure
          q.clear
        end
      end
      
      if SEQUEL_POSTGRES_USES_PG
        # Hash of prepared statements for this connection.  Keys are
        # string names of the server side prepared statement, and values
        # are SQL strings.
        def prepared_statements
          @prepared_statements ||= {}
        end
      end
      
      private
      
      # Return the requested values for the given row.
      def result_set_values(r, *vals)
        return if r.nil? || (r.ntuples == 0)
        case vals.length
        when 1
          r.getvalue(0, vals.first)
        else
          vals.collect{|col| r.getvalue(0, col)}
        end
      end
    end
    
    # Database class for PostgreSQL databases used with Sequel and the
    # pg, postgres, or postgres-pr driver.
    class Database < Sequel::Database
      include Sequel::Postgres::DatabaseMethods
      
      set_adapter_scheme :postgres
      
      # Connects to the database.  In addition to the standard database
      # options, using the :encoding or :charset option changes the
      # client encoding for the connection.
      def connect
        conn = Adapter.connect(
          @opts[:host] || 'localhost',
          @opts[:port] || 5432,
          '', '',
          @opts[:database],
          @opts[:user],
          @opts[:password]
        )
        if encoding = @opts[:encoding] || @opts[:charset]
          conn.set_client_encoding(encoding)
        end
        conn
      end
      
      # Return instance of Sequel::Postgres::Dataset with the given options.
      def dataset(opts = nil)
        Postgres::Dataset.new(self, opts)
      end
      
      # Disconnect all active connections.
      def disconnect
        @pool.disconnect {|c| c.finish}
      end
      
      # Execute the given SQL with the given args on an available connection.
      def execute(sql, *args, &block)
        begin
          log_info(sql, *args)
          synchronize{|conn| conn.execute(sql, *args, &block)}
        rescue => e
          log_info(e.message)
          raise convert_pgerror(e)
        end
      end
      
      # Execute the prepared statement with the given name on an available
      # connection, using the given args.  If the connection has not prepared
      # a statement with the given name yet, prepare it.  If the connection
      # has prepared a statement with the same name and different SQL,
      # deallocate that statement first and then prepare this statement.
      # If a block is given, yield the result, otherwise, return the number
      # of rows changed.  If the :insert option is passed, return the value
      # of the primary key for the last inserted row.
      def execute_prepared_statement(name, args, opts={})
        ps = prepared_statements[name]
        sql = ps.prepared_sql
        ps_name = name.to_s
        synchronize do |conn|
          unless conn.prepared_statements[ps_name] == sql
            if conn.prepared_statements.include?(ps_name)
              s = "DEALLOCATE #{ps_name}"
              log_info(s)
              conn.execute(s) unless conn.prepared_statements[ps_name] == sql
            end
            conn.prepared_statements[ps_name] = sql
            log_info("PREPARE #{ps_name} AS #{sql}")
            conn.prepare(ps_name, sql)
          end
          log_info("EXECUTE #{ps_name}", args)
          q = conn.exec_prepared(ps_name, args)
          if opts[:insert]
            insert_result(conn, *opts[:insert])
          else
            begin
              block_given? ? yield(q) : q.cmd_tuples
            ensure
              q.clear
            end
          end
        end
      end
      
      private

      # PostgreSQL doesn't need the connection pool to convert exceptions.
      def connection_pool_default_options
        super.merge(:pool_convert_exceptions=>false)
      end
    end
    
    # Dataset class for PostgreSQL datasets that use the pg, postgres, or
    # postgres-pr driver.
    class Dataset < Sequel::Dataset
      include Sequel::Postgres::DatasetMethods
      
      # yield all rows returned by executing the given SQL and converting
      # the types.
      def fetch_rows(sql)
        @columns = []
        execute(sql) do |res|
          (0...res.ntuples).each do |recnum|
            converted_rec = {}
            (0...res.nfields).each do |fieldnum|
              fieldsym = res.fname(fieldnum).to_sym
              @columns << fieldsym
              converted_rec[fieldsym] = if value = res.getvalue(recnum,fieldnum)
                (PG_TYPES[res.ftype(fieldnum)] || lambda{|s| s.to_s}).call(value)
              else
                value
              end
            end
            yield converted_rec
          end
        end
      end
      
      if SEQUEL_POSTGRES_USES_PG
        
        PREPARED_ARG_PLACEHOLDER = '$'.lit.freeze
        
        # PostgreSQL specific argument mapper used for mapping the named
        # argument hash to a array with numbered arguments.  Only used with
        # the pg driver.
        module ArgumentMapper
          include Sequel::Dataset::ArgumentMapper
          
          protected
          
          # Return an array of strings for each of the hash values, inserting
          # them to the correct position in the array.
          def map_to_prepared_args(hash)
            array = []
            @prepared_args.each{|k,v| array[v] = hash[k].to_s}
            array
          end
          
          private
          
          # PostgreSQL most of the time requires type information for each of
          # arguments to a prepared statement.  Handle this by allowing the
          # named argument to have a __* suffix, with the * being the type.
          # In the generated SQL, cast the bound argument to that type to
          # elminate ambiguity (and PostgreSQL from raising an exception).
          def prepared_arg(k)
            y, type = k.to_s.split("__")
            "#{prepared_arg_placeholder}#{@prepared_args[y.to_sym]}#{"::#{type}" if type}".lit
          end
          
          # If the named argument has already been used, return the position in
          # the output array that it is mapped to.  Otherwise, map it to the
          # next position in the array.
          def prepared_args_hash
            max_prepared_arg = 0
            Hash.new do |h,k|
              h[k] = max_prepared_arg
              max_prepared_arg += 1
            end
          end
        end
        
        # Allow use of bind arguments for PostgreSQL using the pg driver.
        module BindArgumentMethods
          include ArgumentMapper
          
          private
          
          # Execute the given SQL with the stored bind arguments.
          def execute(sql, &block)
            @db.execute(sql, bind_arguments, &block)
          end
          alias execute_dui execute
          
          # Execute the given SQL with the stored bind arguments, returning
          # the primary key value for the inserted row.
          def execute_insert(sql, table, values)
            @db.execute_insert(sql, table, values, bind_arguments)
          end
        end
        
        # Allow use of server side prepared statements for PostgreSQL using the
        # pg driver.
        module PreparedStatementMethods
          include ArgumentMapper
          
          private
          
          # Execute the stored prepared statement name and the stored bind
          # arguments instead of the SQL given.
          def execute(sql, &block)
            @db.execute_prepared_statement(prepared_statement_name, bind_arguments, &block)
          end
          alias execute_dui execute
          
          # Execute the stored prepared statement name and the stored bind
          # arguments instead of the SQL given, returning the primary key value
          # for the last inserted row.
          def execute_insert(sql, table, values)
            @db.execute_prepared_statement(prepared_statement_name, bind_arguments, :insert=>[table, values])
          end
        end
        
        # Execute the given type of statement with the hash of values.
        def call(type, hash, values=nil, &block)
          ps = to_prepared_statement(type, values)
          ps.extend(BindArgumentMethods)
          ps.call(hash, &block)
        end
        
        # Prepare the given type of statement with the given name, and store
        # it in the database to be called later.
        def prepare(type, name, values=nil)
          ps = to_prepared_statement(type, values)
          ps.extend(PreparedStatementMethods)
          ps.prepared_statement_name = name
          db.prepared_statements[name] = ps
        end
        
        private
        
        # PostgreSQL uses $N for placeholders instead of ?, so use a $
        # as the placeholder.
        def prepared_arg_placeholder
          PREPARED_ARG_PLACEHOLDER
        end
      end
    end
  end
end
