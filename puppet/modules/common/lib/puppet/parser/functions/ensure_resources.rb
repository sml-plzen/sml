Puppet::Parser::Functions::newfunction(:ensure_resources, :type => :statement, :doc => "
  Takes an array of resource reference, and an optional hash of attributes to be defined for those
  resources.

  Creates a resource correseponding to each reference given if not already present in the catalog.
  Uses the specified attributes both when checking if the matching resource already exists and when
  creating it if it does not.

    user { 'dan':
      ensure => present,
    }

    # this only creates the resource if it does not already exist
    ensure_resources(User['dan'], {'ensure' => 'present' })
") do |arguments|
  raise(ArgumentError, "ensure_resources(): Wrong number of " +
    "arguments given (#{arguments.size} for 1 or 2)") if (arguments.size < 1 || arguments.size > 2)
  references, params = arguments
  references = [references] unless references.is_a?(Array)
  params ||= {}

  # ensure the functions are loaded
  [:defined_with_params, :create_resources].each do |name|
    raise Puppet::ParseError, "Unknown function #{name}" unless Puppet::Parser::Functions.function(name)
  end

  references.each do |reference|
    raise(ArgumentError, 'ensure_resources(): #{reference} is not a resource reference') unless reference.is_a?(Puppet::Resource)
    if function_defined_with_params([reference, params])
      Puppet.debug("Resource #{reference} does not need to be created b/c it already exists")
    else
      function_create_resources([reference.type.downcase, { reference.title => params }])
    end
  end
end
