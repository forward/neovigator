require 'rubygems'
require 'neography'
require 'sinatra/base'
require 'uri'

class Neovigator < Sinatra::Application
  set :haml, :format => :html5 
  set :app_file, __FILE__

  configure :test do
    require 'net-http-spy'
    Net::HTTP.http_logger_options = {:verbose => true} 
  end

  helpers do
    def link_to(url, text=url, opts={})
      attributes = ""
      opts.each { |key,value| attributes << key.to_s << "=\"" << value << "\" "}
      "<a href=\"#{url}\" #{attributes}>#{text}</a>"
    end

    def neo
      @neo = Neography::Rest.new(ENV['NEO4J_URL'] || "http://localhost:7474")
    end
  end

  def create_graph    
    graph_exists = neo.get_node_properties(1)
    return if graph_exists && graph_exists['name']
    
    data = HTTParty.get("http://10.0.210.57:9292/data")
    instances = data["eu-west-1"]["ec2_instances"]
    instance_neo_map = {}
    instances.each do |id, instance|
      instance_neo_map[id] = create_node(id, instance)
    end
    
    elbs = data["eu-west-1"]["elbs"]
    elbs.each do |name, elb|
      create_elb(name, elb, instance_neo_map)
    end
    
    traffic = data["eu-west-1"]["network_traffic"]
    traffic.each do |instance_id, traffic|
      traffic["destinations"].each do |destination|
        create_join(instance_neo_map[instance_id], instance_neo_map[destination], "PORT") if instance_neo_map[destination]
      end
    end
    
    @neo.set_node_properties(0, name: "T'internet")
  end

  def create_join(node1, node2, rel_type)
    neo.create_relationship(rel_type, node1, node2)
  end

  def create_node(id, instance)
    name = instance["tags"]["Name"]
    type = type_from_name(name)
    neo.create_node({
      "name" => name,
      "instance" => id,
      "dns_name" => instance["dns_name"],
      "size" => instance["type"],
      "internal_ip" => instance["private_ip_address"],
      "type" => type,
      "roles" => instance["tags"]["Roles"],
      "project" => instance["tags"]["Project"]
    })
  end
  
  def create_elb(name, elb, instances)
    elb_id = neo.create_node({
      "name" => name,
      "dns_name" => elb["dns"],
      "type" => "lb",
    })
    create_join(0, elb_id, "All the internets")
    
    elb["instances"].each do |instance_id|
      create_join(elb_id, instances[instance_id], "PORT")
    end
  end

  def type_from_name(name)
    case name
    when /-lb/
      'lb'
    when /web/
      'web'
    when /mongo/
    when /db/  
      'db'
    else
      ''
    end
  end

  def neighbours
    {"order"         => "depth first",
     "uniqueness"    => "none",
     "return filter" => {"language" => "builtin", "name" => "all_but_start_node"},
     "depth"         => 1}
  end

  def node_id(node)
    case node
      when Hash
        node["self"].split('/').last
      when String
        node.split('/').last
      else
        node
    end
  end

  def get_properties(node)
    properties = "<ul>"
    node["data"].each_pair do |key, value|
        properties << "<li><b>#{key}:</b> #{value}</li>"
      end
    properties + "</ul>"
  end

  get '/resources/show' do
    content_type :json

    node = neo.get_node(params[:id]) 
    connections = neo.traverse(node, "fullpath", neighbours)
    incoming = Hash.new{|h, k| h[k] = []}
    outgoing = Hash.new{|h, k| h[k] = []}
    nodes = Hash.new
    attributes = Array.new

    connections.each do |c|
       c["nodes"].each do |n|
         nodes[n["self"]] = n["data"]
       end
       rel = c["relationships"][0]

       if rel["end"] == node["self"]
         incoming["Incoming:#{rel["type"]}"] << {:values => nodes[rel["start"]].merge({:id => node_id(rel["start"]) }) }
       else
         outgoing["Outgoing:#{rel["type"]}"] << {:values => nodes[rel["end"]].merge({:id => node_id(rel["end"]) }) }
       end
    end

      incoming.merge(outgoing).each_pair do |key, value|
        attributes << {:id => key.split(':').last, :name => key, :values => value.collect{|v| v[:values]} }
      end

   attributes = [{"name" => "No Relationships","name" => "No Relationships","values" => [{"id" => "#{params[:id]}","name" => "No Relationships "}]}] if attributes.empty?

    @node = {:details_html => "<h2>Instance ID: #{node_id(node)}</h2>\n<p class='summary'>\n#{get_properties(node)}</p>\n",
              :data => {:attributes => attributes, 
                        :name => node["data"]["name"],
                        :id => node_id(node),
                        :type => node["data"]["type"]}
            }

    @node.to_json

  end

  get '/' do
    create_graph
    @neoid = params["neoid"]
    haml :index
  end
end
