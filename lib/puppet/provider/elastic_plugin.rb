require 'uri'
require 'puppet_x/elastic/es_versioning'
require 'puppet_x/elastic/plugin_name'

class Puppet::Provider::ElasticPlugin < Puppet::Provider

  def homedir
    case Facter.value('osfamily')
    when 'OpenBSD'
      '/usr/local/elasticsearch'
    else
      '/usr/share/elasticsearch'
    end
  end

  def exists?
    if !File.exists?(pluginfile)
      debug "Plugin file #{pluginfile} does not exist"
      return false
    elsif File.exists?(pluginfile) && readpluginfile != pluginfile_content
      debug "Got #{readpluginfile} Expected #{pluginfile_content}. Removing for reinstall"
      self.destroy
      return false
    else
      debug "Plugin exists"
      return true
    end
  end

  def pluginfile_content
    return @resource[:name] if is1x?

    if @resource[:name].split("/").count == 1 # Official plugin
      version = plugin_version(@resource[:name])
      return "#{@resource[:name]}/#{version}"
    else
      return @resource[:name]
    end
  end

  def pluginfile
    if @resource[:plugin_path]
      File.join(
        @resource[:plugin_dir],
        @resource[:plugin_path],
        '.name'
      )
    else
      File.join(
        @resource[:plugin_dir],
        Puppet_X::Elastic::plugin_name(@resource[:name]),
        '.name'
      )
    end
  end

  def writepluginfile
    File.open(pluginfile, 'w') do |file|
      file.write pluginfile_content
    end
  end

  def readpluginfile
    f = File.open(pluginfile)
    f.readline
  end

  def install1x
    if !@resource[:url].nil?
      [
        Puppet_X::Elastic::plugin_name(@resource[:name]),
        '--url',
        @resource[:url]
      ]
    elsif !@resource[:source].nil?
      [
        Puppet_X::Elastic::plugin_name(@resource[:name]),
        '--url',
        "file://#{@resource[:source]}"
      ]
    else
      [
        @resource[:name]
      ]
    end
  end

  def install2x
    if !@resource[:url].nil?
      [
        @resource[:url]
      ]
    elsif !@resource[:source].nil?
      [
        "file://#{@resource[:source]}"
      ]
    else
      [
        @resource[:name]
      ]
    end
  end

  def proxy_args url
    parsed = URI(url)
    ['http', 'https'].map do |schema|
      [:host, :port, :user, :password].map do |param|
        option = parsed.send(param)
        if not option.nil?
          "-D#{schema}.proxy#{param.to_s.capitalize}=#{option}"
        end
      end
    end.flatten.compact
  end

  def create
    commands = []
    commands += proxy_args(@resource[:proxy]) if is2x? and @resource[:proxy]
    commands << 'install'
    commands << '--batch' if batch_capable?
    commands += is1x? ? install1x : install2x
    debug("Commands: #{commands.inspect}")

    retry_count = 3
    retry_times = 0
    begin
      with_environment do
        plugin(commands)
      end
    rescue Puppet::ExecutionFailure => e
      retry_times += 1
      debug("Failed to install plugin. Retrying... #{retry_times} of #{retry_count}")
      sleep 2
      retry if retry_times < retry_count
      raise "Failed to install plugin. Received error: #{e.inspect}"
    end

    writepluginfile
  end

  def destroy
    with_environment do
      plugin(['remove', Puppet_X::Elastic::plugin_name(@resource[:name])])
    end
  end

  def es_version
    Puppet_X::Elastic::EsVersioning.version(
      resource[:elasticsearch_package_name], resource.catalog
    )
  end

  def is1x?
    Puppet::Util::Package.versioncmp(es_version, '2.0.0') < 0
  end

  def is2x?
    (Puppet::Util::Package.versioncmp(es_version, '2.0.0') >= 0) && (Puppet::Util::Package.versioncmp(es_version, '3.0.0') < 0)
  end

  def batch_capable?
    Puppet::Util::Package.versioncmp(es_version, '2.2.0') >= 0
  end

  def plugin_version(plugin_name)
    _vendor, _plugin, version = plugin_name.split('/')
    return es_version if is2x? && version.nil?
    return version.scan(/\d+\.\d+\.\d+(?:\-\S+)?/).first unless version.nil?
    false
  end

  # Run a command wrapped in necessary env vars
  def with_environment(&block)
    env_vars = {
      'ES_JAVA_OPTS' => []
    }
    saved_vars = {}

    if !is2x? and @resource[:proxy]
      env_vars['ES_JAVA_OPTS'] += proxy_args(@resource[:proxy])
    end

    env_vars['ES_JAVA_OPTS'] = env_vars['ES_JAVA_OPTS'].join(' ')

    env_vars.each do |env_var, value|
      saved_vars[env_var] = ENV[env_var]
      ENV[env_var] = value
    end

    ret = block.call

    saved_vars.each do |env_var, value|
      ENV[env_var] = value
    end

    ret
  end
end
