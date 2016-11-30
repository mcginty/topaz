require "./topaz/*"
require "singleton"
require "mysql"
require "sqlite3"

module Topaz
  class Db < SingleTon
    
    st_fields(
      {st_type: :property, name: info,  type: String, df: ""},
      {st_type: :property, name: setup, type: Bool,   df: false}
    )

    def self.setup(info)
      db = self.get_instance
      Topaz::Logger.e("Topaz is already setup") if db.setup
      db.info = info
      db.setup = true
    end

    def self.clean
      db = self.get_instance
      db.info = ""
      db.setup = false
    end

    def self.type
      
      db = Db.get_instance
      
      Topaz::Logger.e("Topaz is not initialized") unless db.setup
      
      if db.info.starts_with?("mysql://")
        :mysql
      elsif db.info.starts_with?("sqlite3://")
        :sqlite3
      else
        Topaz::Logger.e("Unkown database: #{db.info}")
      end
    end

    def self.open(&block)
      topaz_db = Db.get_instance
      real_db  = DB.open topaz_db.info
      yield real_db
    end
  end

  def self.db
    db = Db.get_instance
    db.info
  end
end
