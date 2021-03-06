module ActiveHash

  class RecordNotFound < StandardError
  end

  class ReservedFieldError < StandardError
  end

  class Base
    class_inheritable_accessor :data, :dirty

    if Object.const_defined?(:ActiveModel)
      extend ActiveModel::Naming
      include ActiveModel::Conversion
    else
      def to_param
        id.present? ? id.to_s : nil
      end
    end

    class << self
      def field_names
        @field_names ||= []
      end

      def the_meta_class
        class << self
          self
        end
      end

      def data=(array_of_hashes)
        mark_dirty
        @records = nil
        write_inheritable_attribute(:data, array_of_hashes)
        if array_of_hashes
          auto_assign_fields(array_of_hashes)
          array_of_hashes.each do |hash|
            insert new(hash)
          end
        end
      end

      def insert(record)
        @records ||= []
        record.attributes[:id] ||= next_id
        mark_dirty
        @records << record
      end

      def next_id
        max_record = all.max { |a, b| a.id <=> b.id }
        if max_record.nil?
          1
        elsif max_record.id.is_a?(Numeric)
          max_record.id.succ
        end
      end

      def create(attributes = {})
        record = new(attributes)
        record.save
        mark_dirty
        record
      end

      alias_method :add, :create

      def create!(attributes = {})
        record = new(attributes)
        record.save!
        record
      end

      def all(options={})
        if options.has_key?(:conditions)
          (@records || []).select do |record|
            options[:conditions].all? {|col, match| record[col] == match}
          end
        else
          @records || []
        end
      end

      def count
        all.length
      end

      def transaction
        yield
      rescue LocalJumpError => err
        raise err
      rescue ActiveRecord::Rollback
      end

      def delete_all
        mark_dirty
        @records = []
      end

      def find(id, * args)
        case id
          when nil
            nil
          when :all
            all
          when Array
            all.select { |record| id.map(& :to_i).include?(record.id) }
          else
            find_by_id(id) || begin
              raise RecordNotFound.new("Couldn't find #{name} with ID=#{id}")
            end
        end
      end

      def find_by_id(id)
        all.detect { |record| record.id == id.to_i }
      end

      delegate :first, :last, :to => :all

      def fields(*args)
        options = args.extract_options!
        args.each do |field|
          field(field, options)
        end
      end

      def field(field_name, options = {})
        validate_field(field_name)
        field_names << field_name

        define_getter_method(field_name, options[:default])
        define_setter_method(field_name)
        define_interrogator_method(field_name)
        define_custom_find_method(field_name)
        define_custom_find_all_method(field_name)
      end

      def validate_field(field_name)
        if [:attributes].include?(field_name.to_sym)
          raise ReservedFieldError.new("#{field_name} is a reserved field in ActiveHash.  Please use another name.")
        end
      end

      private :validate_field

      def respond_to?(method_name, include_private=false)
        super ||
          begin
            config = configuration_for_custom_finder(method_name)
            config && config[:fields].all? do |field|
              field_names.include?(field.to_sym) || field.to_sym == :id
            end
          end
      end

      def method_missing(method_name, *args)
        return super unless respond_to? method_name

        config = configuration_for_custom_finder(method_name)
        attribute_pairs = config[:fields].zip(args)
        matches = all.select { |base| attribute_pairs.all? { |field, value| base.send(field).to_s == value.to_s } }

        if config[:all?]
          matches
        else
          result = matches.first
          if config[:bang?]
            result || raise(RecordNotFound, "Couldn\'t find #{name} with #{attribute_pairs.collect {|pair| "#{pair[0]} = #{pair[1]}"}.join(', ')}")
          else
            result
          end
        end
      end

      def configuration_for_custom_finder(finder_name)
        if finder_name.to_s.match(/^find_(all_)?by_(.*?)(!)?$/) && !($1 && $3)
          {
            :all?   => !!$1,
            :bang?  => !!$3,
            :fields => $2.split('_and_')
          }
        end
      end

      private :configuration_for_custom_finder

      def define_getter_method(field, default_value)
        unless has_instance_method?(field)
          define_method(field) do
            attributes[field].nil? ? default_value : attributes[field]
          end
        end
      end

      private :define_getter_method

      def define_setter_method(field)
        method_name = "#{field}="
        unless has_instance_method?(method_name)
          define_method(method_name) do |new_val|
            attributes[field] = new_val
          end
        end
      end

      private :define_setter_method

      def define_interrogator_method(field)
        method_name = :"#{field}?"
        unless has_instance_method?(method_name)
          define_method(method_name) do
            send(field).present?
          end
        end
      end

      private :define_interrogator_method

      def define_custom_find_method(field_name)
        method_name = :"find_by_#{field_name}"
        unless has_singleton_method?(method_name)
          the_meta_class.instance_eval do
            define_method(method_name) do |*args|
              options = args.extract_options!
              identifier = args[0]
              all.detect { |record| record.send(field_name) == identifier }
            end
          end
        end
      end

      private :define_custom_find_method

      def define_custom_find_all_method(field_name)
        method_name = :"find_all_by_#{field_name}"
        unless has_singleton_method?(method_name)
          the_meta_class.instance_eval do
            unless singleton_methods.include?(method_name)
              define_method(method_name) do |*args|
                options = args.extract_options!
                identifier = args[0]
                all.select { |record| record.send(field_name) == identifier }
              end
            end
          end
        end
      end

      private :define_custom_find_all_method

      def auto_assign_fields(array_of_hashes)
        (array_of_hashes || []).inject([]) do |array, row|
          row.symbolize_keys!
          row.keys.each do |key|
            unless key.to_s == "id"
              array << key
            end
          end
          array
        end.uniq.each do |key|
          field key
        end
      end

      private :auto_assign_fields

      # Needed for ActiveRecord polymorphic associations
      def base_class
        ActiveHash::Base
      end

      def reload
        self.data = read_inheritable_attribute(:data)
        mark_clean
      end

      private :reload

      def mark_dirty
        self.dirty = true
      end

      private :mark_dirty

      def mark_clean
        self.dirty = false
      end

      private :mark_clean

      def has_instance_method?(name)
        instance_methods.map{|method| method.to_sym}.include?(name)
      end

      private :has_instance_method?

      def has_singleton_method?(name)
        singleton_methods.map{|method| method.to_sym}.include?(name)
      end

      private :has_singleton_method?

    end

    attr_reader :attributes

    def initialize(attributes = {})
      attributes.symbolize_keys!
      @attributes = attributes
      attributes.dup.each do |key, value|
        send "#{key}=", value
      end
    end

    def [](key)
      attributes[key]
    end

    def []=(key, val)
      attributes[key] = val
    end

    def id
      attributes[:id] ? attributes[:id] : nil
    end

    def id=(id)
      attributes[:id] = id
    end

    alias quoted_id id

    def new_record?
      !self.class.all.include?(self)
    end

    def destroyed?
      false
    end

    def persisted?
      self.class.all.map(&:id).include?(id)
    end

    def readonly?
      true
    end

    def eql?(other)
      other.instance_of?(self.class) and not id.nil? and (id == other.id)
    end

    alias == eql?

    def hash
      id.hash
    end

    def cache_key
      case
      when new_record?
        "#{self.class.model_name.cache_key}/new"
      when timestamp = self[:updated_at]
        "#{self.class.model_name.cache_key}/#{id}-#{timestamp.to_s(:number)}"
      else
        "#{self.class.model_name.cache_key}/#{id}"
      end
    end

    def errors
      obj = Object.new

      def obj.[](key)
        []
      end

      def obj.full_messages()
        []
      end

      obj
    end

    def save(*args)
      self.class.insert(self)
      true
    end

    alias save! save

    def valid?
      true
    end

    def marked_for_destruction?
      false
    end

  end
end
