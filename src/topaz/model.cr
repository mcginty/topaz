require "json"

# This is a main wrapper class for Topaz models.
# Any class extending Topaz::Model can be transparent models for any databases.
# The model have to call `columns` macro even if you don't have any columns
# since the calling contruct every necessary functions
module Topaz
  class Model
    @q    : String?
    @args : Array(DB::Any)?
    @tx   : DB::Transaction?

    macro columns(_cols)
      {% id_type = _cols[:id] ? _cols[:id] : Int32 %}

      {% cols = {} of KeyType => ValueType %}
      {% for key, value in _cols %}
        {% cols[key] = value if key != :id %}
      {% end %}

      @id : {{ id_type }} = {{ id_type }}.new(-1) # Int32.new(-1) | Int64.new(-1)

      JSON.mapping(
        id: {{ id_type }},
        {% for key, value in cols %}
          {% if value.is_a?(NamedTupleLiteral) %}
            {{key.id}}: {{value[:type]}}?,
          {% else %}
            {{key.id}}: {{value.id}}?,
          {% end %}
        {% end %}
        created_at: Time?,
        updated_at: Time?)

      def initialize({% for key, value in cols %}
                       {% if value.is_a?(NamedTupleLiteral) %}
                         {% if value[:nullable] %}
                           {% if value[:default] %}
                             @{{key.id}} : {{value[:type]}}? = {{value[:default]}},
                           {% else %}
                             @{{key.id}} : {{value[:type]}}? = nil,
                           {% end %}
                         {% else %}
                           {% if value[:default] %}
                             @{{key.id}} : {{value[:type]}} = {{value[:default]}},
                           {% else %}
                             @{{key.id}} : {{value[:type]}},
                           {% end %}
                         {% end %}
                       {% else %}
                         @{{key.id}} : {{value.id}},
                       {% end %}
                     {% end %})
      end

      protected def initialize(@id : {{ id_type }},
                               {% for key, value in cols %}
                                 {% if value.is_a?(NamedTupleLiteral) %}
                                   @{{key.id}} : {{value[:type]}}?,
                                 {% else %}
                                   @{{key.id}} : {{value.id}}?,
                                 {% end %}
                               {% end %}@created_at : Time, @updated_at : Time)
      end

      protected def initialize
        {% for key, value in cols %}
          @{{key.id}} = nil
        {% end %}
      end

      protected def set_query(q)
        @q = q
        self
      end

      def self.in(tx : DB::Transaction)
        new.in(tx)
      end

      def self.find(id)
        new.set_query("where id = #{id}").select.first
      end

      def self.where(q : String)
        new.set_query("where #{q} ")
      end

      def self.order(column : String, sort = "asc")
        new.set_query("order by #{column} #{sort} ")
      end

      def self.range(offset : Int, limit : Int)
        new.set_query("limit #{limit} offset #{offset} ")
      end

      def self.select
        new.select
      end

      def self.update(**data)
        new.update(**data)
      end

      def self.delete
        new.delete
      end

      def in(tx : DB::Transaction)
        @tx = tx
        self
      end

      def find(id)
        model = typeof(self).new
        model.in(@tx.as(DB::Transaction)) unless @tx.nil?
        model.set_query("where id = #{id}").select.first
      end

      def where(q : String)
        @q = "#{@q}where #{q} "
        self
      end

      def and(q : String)
        @q = "#{@q}and #{q} "
        self
      end

      def or(q : String)
        @q = "#{@q}or #{q} "
        self
      end

      def order(column : String, sort = "asc")
        @q = "#{@q}order by #{column} #{sort} "
        self
      end

      def range(offset : Int, limit : Int)
        @q = "#{@q}limit #{limit} offset #{offset} "
        self
      end

      def delete
        @q = "where id = #{@id}" unless new_record?
        @q = "delete from #{table_name} #{@q}"
        exec
        @destroyed = true
        refresh
      end

      def destroyed?
        @destroyed ||= false
      end

      def new_record?
        @id == -1
      end

      def persisted?
        !(new_record? || destroyed?)
      end

      def update(**data)

        @q = "where id = #{@id}" unless new_record?

        updated = ""

        time = Time.now
        args = [] of DB::Any

        if data.keys.size == 0
          {% for key, value, idx in cols %}
            {% if value.is_a?(NamedTupleLiteral) %}
              {% if value[:nullable] %}
                unless @{{key.id}}.nil?
                  updated += "{{key.id}} = ?, "
                  args << to_parameterized_value(@{{key.id}}, true)
                else
                  updated += "{{key.id}} = null, "
                end
              {% else %}
                unless @{{key.id}}.nil?
                  updated += "{{key.id}} = ?, "
                  args << to_parameterized_value(@{{key.id}})
                end
              {% end %}
            {% else %}
              unless @{{key.id}}.nil?
                updated += "{{key.id}} = ?, "
                args << to_parameterized_value(@{{key.id}})
              end
            {% end %}
          {% end %}
        else
          data.each_with_index do |key, value, idx|
            unless value.nil?
              updated += "#{key} = ?, "
              args << to_parameterized_value(value)
              set_value_of(key.to_s, value) unless new_record?
            else
              updated += "#{key} = null, "
              set_value_of(key.to_s, value) unless new_record?
            end
          end
        end

        updated += "updated_at = \'#{time.to_s(Topaz::Db.time_format)}\'"
        @updated_at = time
        @q = "update #{table_name} set #{updated} #{@q}"
        @args = args
        exec
        refresh
      end

      protected def set_value_of(_key : String, _value : DB::Any)
        {% if cols.size > 0 %}
          case _key
               {% for key, value in cols %}
               when "{{key.id}}"
                 {% if value.is_a?(NamedTupleLiteral) %}
                   @{{key.id}} = _value if _value.is_a?({{value[:type]}})
                 {% else %}
                   @{{key.id}} = _value if _value.is_a?({{value.id}})
                 {% end %}
               {% end %}
          end
        {% end %}
      end

      def select
        @q = "select * from #{table_name} #{@q}"
        Topaz::Log.q @q.as(String), @tx unless @q.nil?

        res = read_result(Topaz::Db.shared) if @tx.nil?
        res = read_result(@tx.as(DB::Transaction).connection) unless @tx.nil?

        raise "Failed to read data from database" if res.nil?

        refresh
        res.as(Set)
      end

      protected def read_value(rows, type : T.class) : T forall T
        if type == Time
          Time.parse(rows.read(String), Topaz::Db.time_format)
        elsif type == Time?
          if val = rows.read(String?)
            Time.parse(val, Topaz::Db.time_format)
          end
        else
          rows.read(type)
        end.as(T)
      end

      protected def read_result(db : DB::Database|DB::Connection)

        set = Set.new

        db.query(@q.as(String)) do |rows|
          rows.each do
            case Topaz::Db.scheme
            when "mysql", "postgres"
              set.push(
                typeof(self).new(
                rows.read({{ id_type.id }}), # id
                {% for key, value in cols %}
                  {% if value.is_a?(NamedTupleLiteral) %}
                    read_value(rows, {{value[:type]}}?),
                  {% else %}
                    read_value(rows, {{value.id}}?),
                  {% end %}
                {% end %}
                read_value(rows, Time),
                read_value(rows, Time)
              ))
            when "sqlite3"
              set.push(
                typeof(self).new(
                {{ id_type }}.new(rows.read(Int64)), # id
                {% for key, value in cols %}
                  {% if value.is_a?(NamedTupleLiteral) %}
                    {% if value[:type].id == "Int32" %}
                      (rows.read(Int64?) || Nilwrapper).to_i32,
                    {% elsif value[:type].id == "Float32" %}
                      (rows.read(Float64?) || Nilwrapper).to_f32,
                    {% else %}
                      read_value(rows, {{value[:type]}}?),
                    {% end %}
                  {% else %}
                    {% if value.id == "Int32" %}
                      (rows.read(Int64?) || Nilwrapper).to_i32,
                    {% elsif value.id == "Float32" %}
                      (rows.read(Float64?) || Nilwrapper).to_f32,
                    {% else %}
                      read_value(rows, {{value.id}}?),
                    {% end %}
                  {% end %}
                {% end %}
                read_value(rows, Time),
                read_value(rows, Time)
              ))
            end
          end
        end unless @q.nil?
        set
      end

      def self.create(
            {% for key, value in cols %}
              {% if value.is_a?(NamedTupleLiteral) %}
                {% if value[:nullable] %}
                  {% if value[:default] %}
                    {{key.id}} : {{value[:type]}}? = {{value[:default]}},
                  {% else %}
                    {{key.id}} : {{value[:type]}}? = nil,
                  {% end %}
                {% else %}
                  {% if value[:default] %}
                    {{key.id}} : {{value[:type]}} = {{value[:default]}},
                  {% else %}
                    {{key.id}} : {{value[:type]}},
                  {% end %}
                {% end %}
              {% else %}
                {{key.id}} : {{value.id}},
              {% end %}
            {% end %}
          )
        model = new({% for key, value in cols %}{{key.id}},{% end %})
        model.save
        model
      end

      def create(
            {% for key, value in cols %}
              {% if value.is_a?(NamedTupleLiteral) %}
                {% if value[:nullable] %}
                  {% if value[:default] %}
                    {{key.id}} : {{value[:type]}}? = {{value[:default]}},
                  {% else %}
                    {{key.id}} : {{value[:type]}}? = nil,
                  {% end %}
                {% else %}
                  {% if value[:default] %}
                    {{key.id}} : {{value[:type]}} = {{value[:default]}},
                  {% else %}
                    {{key.id}} : {{value[:type]}},
                  {% end %}
                {% end %}
              {% else %}
                {{key.id}} : {{value.id}},
              {% end %}
            {% end %}
          )
        model = typeof(self).new({% for key, value in cols %}{{key.id}},{% end %})
        model.in(@tx.as(DB::Transaction)) unless @tx.nil?
        model.save
        model
      end

      private def to_parameterized_value(val, nullable = false) : String
        case val
        when Time then "#{val.to_s(Topaz::Db.time_format)}"
        else "#{val}"
        end
      end

      private def to_db_value(val, nullable = false) : String
        case val
        when Time then "'#{val.to_s(Topaz::Db.time_format)}'"
        else "'#{val}'"
        end
      end

      def save
        keys = [] of String
        vals = [] of DB::Any

        {% for key, value in cols %}
          {% if value.is_a?(NamedTupleLiteral) %}
            {% if value[:nullable] %}
              keys.push("{{key.id}}")
              vals.push(to_parameterized_value(@{{key.id}}, nullable: true)) unless @{{key.id}}.nil?
              vals.push(nil) if @{{key.id}}.nil?
            {% else %}
              keys.push("{{key.id}}") unless @{{key.id}}.nil?
              vals.push(to_parameterized_value(@{{key.id}})) unless @{{key.id}}.nil?
            {% end %}
          {% else %}
            keys.push("{{key.id}}") unless @{{key.id}}.nil?
            vals.push(to_parameterized_value(@{{key.id}})) unless @{{key.id}}.nil?
          {% end %}
        {% end %}

        time = Time.now

        keys.push("created_at")
        keys.push("updated_at")
        vals.push("#{time.to_s(Topaz::Db.time_format)}")
        vals.push("#{time.to_s(Topaz::Db.time_format)}")

        _keys = keys.join(", ")
        _vals = vals.map{ |v| "?" }.join(", ")

        @q = "insert into #{table_name}(#{_keys}) values(#{_vals})"
        @args = vals

        res = exec

        # Note: Postgres doesn't support this
        if new_record? && Topaz::Db.scheme == "postgres"
          @id = find_id_for_postgres(Topaz::Db.shared) if @tx.nil?
          @id = find_id_for_postgres(@tx.as(DB::Transaction).connection) unless @tx.nil?
        else
          @id = {{ id_type }}.new(res.last_insert_id)
        end

        @created_at = time
        @updated_at = time

        refresh

        self
      end

      protected def find_id_for_postgres(db : DB::Database|DB::Connection)
        id : Int64 = -1i64
        db.query("select currval(\'#{table_name}_seq\')") do |rows|
          rows.each do
            id = rows.read(Int64)
          end
        end
        {{ id_type }}.new(id)
      end

      def to_a
        [
          ["id", @id],
          {% for key, value in cols %}["{{key.id}}", @{{key.id}}],{% end %}
            ["created_at", "#{@created_at}"],
          ["updated_at", "#{@updated_at}"],
        ]
      end

      def to_h
        {
          "id" => @id,
          {% for key, value in cols %}"{{key.id}}" => @{{key.id}},{% end %}
            "created_at" => "#{@created_at}",
          "updated_at" => "#{@updated_at}",
        }
      end

      protected def self.registered_columns
        arr = Array(String).new
        arr.push("id")
        q = ""
        case Topaz::Db.scheme
        when "mysql"
          q = "show columns from #{table_name}"
        when "postgres"
          q = "select column_name, data_type from information_schema.columns where table_name = \'#{table_name}\'"
        when "sqlite3"
          q = "pragma table_info(\'#{table_name}\')"
        end
        Topaz::Db.shared.query(q) do |rows|
          rows.each do
            rows.read(Int32) if Topaz::Db.scheme == "sqlite3"
            name = rows.read(String)
            if name != "id" && name != "created_at" && name != "updated_at"
              arr.push(name)
            end
          end
        end
        arr.push("created_at")
        arr.push("updated_at")
        arr
      end

      protected def self.defined_columns
        arr = Array(String).new
        arr.push("id")
        {% for key, value in cols %}
          {% if value.is_a?(NamedTupleLiteral) %}
            arr.push("{{key.id}}")
          {% else %}
            arr.push("{{key.id}}")
          {% end %}
        {% end %}
          arr.push("created_at")
        arr.push("updated_at")
        arr
      end

      protected def self.copy_data_from_old

        copied_columns = Array(String).new
        defined = defined_columns

        registered_columns.each do |col|
          copied_columns.push(col) if defined.includes?(col)
        end

        copied = copied_columns.join(", ")
        "insert into #{table_name}(#{copied}) select #{copied} from #{table_name}_old"
      end

      def self.migrate_table
        copy_query = copy_data_from_old
        Topaz::Db.shared.transaction do |tx|
          tx.connection.exec "alter table #{table_name} rename to #{table_name}_old"
          tx.connection.exec create_table_query
          tx.connection.exec copy_query
          tx.connection.exec "drop table if exists #{table_name}_old"
          tx.commit
        end
      end

      def self.create_table_query
        q = ""
        case Topaz::Db.scheme
        when "mysql"
          q =  <<-QUERY
          create table if not exists #{table_name}(id #{get_type({{ id_type }})} not null auto_increment,
          {% for key, value in cols %}
          {% if value.is_a?(NamedTupleLiteral) %}
          {{key.id}} #{get_type({{value[:type]}})}
          {% if value[:nullable] != nil && value[:nullable] %}
           null
          {% elsif value[:nullable] != nil && !value[:nullable] %}
           not null
          {% end %},
          {% else %}
          {{key.id}} #{get_type({{value.id}})},
          {% end %}{% end %}
          created_at varchar(64),
          updated_at varchar(64),
          index(id));
          QUERY
        when "postgres"
          q =  <<-QUERY
          create table if not exists #{table_name}(id #{get_type({{ id_type }})} default nextval(\'#{table_name}_seq\') not null
          {% for key, value in cols %}
          {% if value.is_a?(NamedTupleLiteral) %}
          ,{{key.id}} #{get_type({{value[:type]}})}
          {% if value[:nullable] != nil && value[:nullable] %}
           null
          {% elsif value[:nullable] != nil && !value[:nullable] %}
           not null
          {% end %}
          {% else %}
          ,{{key.id}} #{get_type({{value.id}})}
          {% end %}{% end %}
          ,created_at varchar(64)
          ,updated_at varchar(64));
          QUERY
        when "sqlite3"
          q = <<-QUERY
          create table if not exists #{table_name}(id #{get_type({{ id_type }})} primary key
          {% for key, value in cols %}
          {% if value.is_a?(NamedTupleLiteral) %}
          ,{{key.id}} #{get_type({{value[:type]}})}
          {% if value[:nullable] != nil && value[:nullable] %}
           null
          {% elsif value[:nullable] != nil && !value[:nullable] %}
           not null
          {% end %}
          {% else %}
          ,{{key.id}} #{get_type({{value.id}})}
          {% end %}{% end %}
          ,created_at varchar(64)
          ,updated_at varchar(64));
          QUERY
        end

        q.gsub("\n", "")
      end

      def self.create_table
        exec "create sequence #{table_name}_seq start 1" if Topaz::Db.scheme == "postgres"
        exec create_table_query
      end

      def self.drop_table
        exec "drop table if exists #{table_name}"
        exec "drop sequence if exists #{table_name}_seq" if Topaz::Db.scheme == "postgres"
      end

      protected def self.exec(q)
        new.set_query(q).exec
      end

      protected def exec
        Topaz::Log.q @q.as(String), @tx unless @q.nil?
        res = nil
        if @args.nil?
          res = Topaz::Db.shared.exec @q.as(String) if @tx.nil? && !@q.nil?
          res = @tx.as(DB::Transaction).connection.exec @q.as(String) unless @tx.nil? && !@q.nil?
        else
          res = Topaz::Db.shared.exec @q.as(String), @args if @tx.nil? && !@q.nil?
          res = @tx.as(DB::Transaction).connection.exec @q.as(String), @args unless @tx.nil? && !@q.nil?
        end
        raise "Failed to execute \'#{@q}\'" if res.nil?
        res.as(DB::ExecResult)
      end

      protected def self.downcase
        class_name = self.to_s.gsub("::", '_')
        class_name = class_name.gsub(/[A-Z]/){ |a| '_' + a.downcase }
        class_name = class_name[1..class_name.size-1] if class_name.starts_with?('_')
        class_name
      end

      def self.table_name
        downcase
      end

      def table_name
        typeof(self).downcase
      end

      protected def refresh
        @q  = ""
        @args = nil
        @tx = nil
      end

      protected def self.get_type(t)
        case t.to_s
        when "String"
          return "text"
        when "Int32"
          return "int" if Topaz::Db.scheme == "mysql"
          return "integer" if Topaz::Db.scheme == "postgres"
          return "integer" if Topaz::Db.scheme == "sqlite3"
        when "Int64"
          return "bigint" if Topaz::Db.scheme == "mysql" || Topaz::Db.scheme == "postgres"
          return "integer" if Topaz::Db.scheme == "sqlite3"
        when "Float32"
          return "float" if Topaz::Db.scheme == "mysql" || Topaz::Db.scheme == "sqlite3"
          return "real" if Topaz::Db.scheme ==  "postgres"
        when "Float64"
          return "double" if Topaz::Db.scheme == "mysql" || Topaz::Db.scheme == "sqlite3"
          return "double precision" if Topaz::Db.scheme == "postgres"
        when "Bool"
          return "tinyint"
        when "Time"
          return "varchar(64)"
        end
      end

      class Set < Array(self)
        # Model set
        def to_json
          "[#{map(&.to_json).join(", ")}]"
        end
      end

      {% for key, value in cols %}
        {% if value.is_a?(NamedTupleLiteral) %}
          {% if value[:nullable] %}
            def {{key.id}}=(@{{key.id}} : {{value[:type]}}?)
            end
            def {{key.id}} : {{value[:type]}}?
                               return @{{key.id}}.as({{value[:type]}}?)
            end
          {% else %}
            def {{key.id}}=(@{{key.id}} : {{value[:type]}})
            end
            def {{key.id}} : {{value[:type]}}
              return @{{key.id}}.as({{value[:type]}})
            end
          {% end %}
        {% else %}
          def {{key.id}}=(@{{key.id}} : {{value.id}})
          end
          def {{key.id}} : {{value.id}}
            return @{{key.id}}.as({{value.id}})
          end
        {% end %}
      {% end %}
    end

    macro columns(**cols)
      {% if cols.size > 0 %}
        columns({{cols}})
      {% else %}
        columns({} of Symbol => String)
      {% end %}
    end

    macro has_many(models)
      {% for key, value in models %}
        def {{key.id}}
          {{value[:model].id}}.where("{{value[:key].id}} = #{@id}").select
        end
      {% end %}

        def elements(ms : Symbol|String)
          {% if models.size > 0 %}
            case ms
                {% for key, value in models %}
                when :{{key.id}}, "{{key.id}}"
                  return {{key.id}}
                {% end %}
            end
          {% end %}
        end
    end

    macro has_many(**models)
      has_many({{models}})
    end

    macro belongs_to(models)
      {% for key, value in models %}
        def {{key.id}}
          {{value[:model].id}}.find({{value[:key].id}})
        end
      {% end %}
    end

    macro belongs_to(**models)
      belongs_to({{models}})
    end
  end
end
