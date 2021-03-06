module ActivePresenter
  # Base class for presenters. See README for usage.
  #
  class Base
    include ActiveSupport::Callbacks
    define_callbacks :before_validation, :before_save, :after_save
    
    class_attribute :presented
    class_attribute :attr_protected, :attr_accessible
    self.presented = {}
    
    # Indicates which models are to be presented by this presenter.
    # i.e.
    #
    #   class SignupPresenter < ActivePresenter::Base
    #     presents :user, :account
    #   end
    #  
    # In the above example, :user will (predictably) become User. If you want to override this behaviour, specify the desired types in a hash, as so:
    #
    #   class PresenterWithTwoAddresses < ActivePresenter::Base
    #     presents :primary_address => Address, :secondary_address => Address
    #   end
    #
    def self.presents(*types)
      types_and_classes = types.extract_options!
      types.each { |t| types_and_classes[t] = t.to_s.tableize.classify.constantize }

      attr_accessor *types_and_classes.keys
      
      types_and_classes.keys.each do |t|
        define_method("#{t}_errors") do
          send(t).errors
        end
        
        presented[t] = types_and_classes[t]
      end
    end
    
    def self.human_attribute_name(attribute_key_name, options = {})
      presentable_type = presented.keys.detect do |type|
        attribute_key_name.to_s.starts_with?("#{type}_") || attribute_key_name.to_s == type.to_s
      end
      attribute_key_name_without_class = attribute_key_name.to_s.gsub("#{presentable_type}_", "")
      
      if presented[presentable_type] and attribute_key_name_without_class != presentable_type.to_s
        presented[presentable_type].human_attribute_name(attribute_key_name_without_class, options)
      else
        I18n.translate(presentable_type, options.merge(:default => presentable_type.to_s.humanize, :scope => [:activerecord, :models]))
      end
    end
    
    # Since ActivePresenter does not descend from ActiveRecord, we need to
    # mimic some ActiveRecord behavior in order for the ActiveRecord::Errors
    # object we're using to work properly.
    #
    # This problem was introduced with Rails 2.3.4.
    # Fix courtesy http://gist.github.com/191263
    def self.self_and_descendants_from_active_record # :nodoc:
      [self]
    end
    
    def self.human_name(options = {}) # :nodoc:
      defaults = self_and_descendants_from_active_record.map do |klass|
        :"#{klass.name.underscore}"
      end 
      defaults << self.name.humanize
      I18n.translate(defaults.shift, {:scope => [:activerecord, :models], :count => 1, :default => defaults}.merge(options))
    end
    
    # Note that +attr_protected+ is still applied to the received hash. Thus,
    # with this technique you can at most _extend_ the list of protected
    # attributes for a particular mass-assignment call.
    def self.attr_protected(*attributes)
      write_inheritable_attribute(:attr_protected, Set.new(attributes.map {|a| a.to_s}) + (protected_attributes || []))
    end
    
    # Returns an array of all the attributes that have been protected from mass-assignment.
    def self.protected_attributes # :nodoc:
      read_inheritable_attribute(:attr_protected)
    end
    
    # Note that +attr_accessible+ is still applied to the received hash. Thus,
    # with this technique you can at most _narrow_ the list of accessible
    # attributes for a particular mass-assignment call.
    def self.attr_accessible(*attributes)
      write_inheritable_attribute(:attr_accessible, Set.new(attributes.map(&:to_s)) + (accessible_attributes || []))
    end
    
    # Returns an array of all the attributes that have been made accessible to mass-assignment.
    def self.accessible_attributes # :nodoc:
      read_inheritable_attribute(:attr_accessible)
    end
    
    # Accepts arguments in two forms. For example, if you had a SignupPresenter that presented User, and Account, you could specify arguments in the following two forms:
    #
    #   1. SignupPresenter.new(:user_login => 'james', :user_password => 'swordfish', :user_password_confirmation => 'swordfish', :account_subdomain => 'giraffesoft')
    #     - This form is useful for initializing a new presenter from the params hash: i.e. SignupPresenter.new(params[:signup_presenter])
    #   2. SignupPresenter.new(:user => User.find(1), :account => Account.find(2))
    #     - This form is useful if you have instances that you'd like to edit using the presenter. You can subsequently call presenter.update_attributes(params[:signup_presenter]) just like with a regular AR instance.
    #
    # Both forms can also be mixed together: SignupPresenter.new(:user => User.find(1), :user_login => 'james')
    #   In this case, the login attribute will be updated on the user instance provided.
    # 
    # If you don't specify an instance, one will be created by calling Model.new
    #
    def initialize(args = {})
      args ||= {}
      
      presented.each do |type, klass|
        value = args.delete(type)
        send("#{type}=", value.is_a?(klass) ? value : klass.new)
      end
      
      self.attributes = args
    end

    # Set the attributes of the presentable instances using
    # the type_attribute form (i.e. user_login => 'james'), or
    # the multiparameter attribute form (i.e. {user_birthday(1i) => "1980", user_birthday(2i) => "3"})
    #
    def attributes=(attrs)
      return if attrs.nil?
      
      attrs = attrs.stringify_keys
      multi_parameter_attributes = {}
      attrs = remove_attributes_protected_from_mass_assignment(attrs)
      
      attrs.each do |k,v|
        if (base_attribute = k.to_s.split("(").first) != k.to_s
          presentable = presentable_for(base_attribute)
          multi_parameter_attributes[presentable] ||= {}
          multi_parameter_attributes[presentable].merge!(flatten_attribute_name(k,presentable).to_sym => v)
        else
          send("#{k}=", v) unless attribute_protected?(k)
        end
      end
      
      multi_parameter_attributes.each do |presentable,multi_attrs|
        send(presentable).send(:attributes=, multi_attrs)
      end
    end
    
    # Makes sure that the presenter is accurate about responding to presentable's attributes, even though they are handled by method_missing.
    #
    def respond_to?(method, include_private = false)
      presented_attribute?(method) || super
    end
    
    # Handles the decision about whether to delegate getters and setters to presentable instances.
    #
    def method_missing(method_name, *args, &block)
      presented_attribute?(method_name) ? delegate_message(method_name, *args, &block) : super
    end
    
    # Returns an instance of ActiveRecord::Errors with all the errors from the presentables merged in using the type_attribute form (i.e. user_login).
    #
    def errors
      @errors ||= ActiveRecord::Errors.new(self)
    end
    
    # Returns boolean based on the validity of the presentables by calling valid? on each of them.
    #
    def valid?
      errors.clear
      if run_callbacks_with_halt(:before_validation)
        presented.keys.each do |type|
          presented_inst = send(type)

          next unless save?(type, presented_inst)
          merge_errors(presented_inst, type) unless presented_inst.valid?
        end

        errors.empty?
      end
    end
    
    # Do any of the attributes have unsaved changes?
    def changed?
      presented_instances.map(&:changed?).any?
    end
    
    # Save all of the presentables, wrapped in a transaction.
    # 
    # Returns true or false based on success.
    #
    def save
      saved = false
      
      ActiveRecord::Base.transaction do
        if valid? && run_callbacks_with_halt(:before_save)
          saved = presented.keys.select {|key| save?(key, send(key))}.all? {|key| send(key).save}
          raise ActiveRecord::Rollback unless saved # TODO: Does this happen implicitly?
        end

        run_callbacks_with_halt(:after_save) if saved
      end
      
      saved
    end
    
    # Save all of the presentables wrapped in a transaction.
    #
    # Returns true on success, will raise otherwise.
    # 
    def save!
      raise ActiveRecord::RecordInvalid.new(self) unless valid?
      raise ActiveRecord::RecordNotSaved unless run_callbacks_with_halt(:before_save)
      
      ActiveRecord::Base.transaction do
        presented.keys.select {|key| save?(key, send(key))}.each {|key| send(key).save!}

        run_callbacks_with_halt(:after_save)
      end

      true
    end
    
    # Update attributes, and save the presentables
    #
    # Returns true or false based on success.
    #
    def update_attributes(attrs)
      self.attributes = attrs
      save
    end
    
    # Should this presented instance be saved?  By default, this returns true
    # Called from #save and #save!
    #
    # For
    #  class SignupPresenter < ActivePresenter::Base
    #    presents :account, :user
    #  end
    #
    # #save? will be called twice:
    #  save?(:account, #<Account:0x1234dead>)
    #  save?(:user, #<User:0xdeadbeef>)
    def save?(presented_key, presented_instance)
      true
    end

    # We define #id and #new_record? to play nice with form_for(@presenter) in Rails
    def id # :nodoc:
      nil
    end
    
    def new_record?
      true
    end

    protected
      def presented_instances
        presented.keys.map { |key| send(key) }
      end
      
      def delegate_message(method_name, *args, &block)
        presentable = presentable_for(method_name)
        send(presentable).send(flatten_attribute_name(method_name, presentable), *args, &block)
      end
      
      def presentable_for(method_name)
        presented.keys.sort_by { |k| k.to_s.size }.reverse.detect do |type|
          method_name.to_s.starts_with?(attribute_prefix(type))
        end
      end
    
      def presented_attribute?(method_name)
        p = presentable_for(method_name)
        !p.nil? && send(p).respond_to?(flatten_attribute_name(method_name,p))
      end
      
      def flatten_attribute_name(name, type)
        name.to_s.gsub(/^#{attribute_prefix(type)}/, '')
      end
      
      def attribute_prefix(type)
        "#{type}_"
      end
      
      def merge_errors(presented_inst, type)
        presented_inst.errors.each do |att,msg|
          if att == 'base'
            errors.add(type, msg)
          else
            errors.add(attribute_prefix(type)+att, msg)
          end
        end
      end
      
      def attribute_protected?(name)
        presentable    = presentable_for(name)
        return false unless presentable
        flat_attribute = {flatten_attribute_name(name, presentable) => ''} #remove_att... normally takes a hash, so we use a ''
        presented[presentable].new.send(:remove_attributes_protected_from_mass_assignment, flat_attribute).empty?
      end
      
      def run_callbacks_with_halt(callback)
        run_callbacks(callback) { |result, object| result == false }
      end
      
      def remove_attributes_protected_from_mass_assignment(attributes)
        if self.class.accessible_attributes.nil? && self.class.protected_attributes.nil?
          attributes
        elsif self.class.protected_attributes.nil?
          attributes.reject { |key, value| !self.class.accessible_attributes.include?(key.gsub(/\(.+/, ""))}
        elsif self.class.accessible_attributes.nil?
          attributes.reject { |key, value| self.class.protected_attributes.include?(key.gsub(/\(.+/,""))}
        else
          raise "Declare either attr_protected or attr_accessible for #{self.class}, but not both."
        end
      end
      
  end
end
