Puppet::Type.type(:likewise_open_setting).provide(:lwconfig) do
  LWCONFIG = 'lwconfig' unless defined?(LWCONFIG)

  class SettingsCache
    class LwconfigDumpParseError < RuntimeError
    end

    def [](key)
      settings[key]
    end

    private

    def settings
      @settings ||= self.class.load_settings
    end

    def self.load_settings
      settings = {}

      command = [LWCONFIG, '--dump']
      # this will raise an exception if the command fails
      lines = Puppet::Util.execute(command).each_line
      while true
        name, value = lines.next.split(/\s+/, 2)
        # TODO value should not be empty either, as that means
        # no value is defined for this settings parameter
        raise LwconfigDumpParseError unless value

        if value.start_with?('"')
          part = value[1..-1]
          value = ''
          while true
            raise LwconfigDumpParseError unless part =~ /^((?:[^\\"]|\\.)*)("?)$/
            value << $1
            break unless $2.empty?
            begin
              part = lines.next
            rescue StopIteration
              raise LwconfigDumpParseError
            end
          end
          value.gsub!(/\\(.)/, '\1')
        else
          value.chomp!
        end

        settings[name] = value
      end
    rescue StopIteration, LwconfigDumpParseError => e
      Puppet.err("Failed to parse output of: #{command.join(' ')}") unless e.is_a?(StopIteration)
      settings
    end
  end

  attr_accessor :cache

  def self.prefetch(settings)
    # create a cache shared by all settings resources
    cache = SettingsCache.new
    settings.each do |setting, resource|
      resource.provider.cache = cache
    end
  end

  def get
    cache[resource[:name]]
  end

  def set
    # this will raise an exception if the command fails
    execute([LWCONFIG, resource[:name], resource[:value]])
  end
end
