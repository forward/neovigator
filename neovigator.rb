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

    lb   = create_server('ih-products-api-lb', "lb")
    web1 = create_server('ih-products-api-web-1', "web")
    web2 = create_server('ih-products-api-web-2', "web")
    db1  = create_server('ih-products-api-db-1', "db")
    db2  = create_server('ih-products-api-db-2', "db")
    
    @neo.set_node_properties(0, name: "T'internet")
    
    create_join(0, lb, "80")
    create_join(lb, web1, "80")
    create_join(lb, web2, "80")
    create_join(web1, db1, "27017")
    create_join(web2, db1, "27017")
    create_join(db1, db2, "27017")
  end

  def create_join(node1, node2, rel_type)
    neo.create_relationship(rel_type, node1, node2)
  end

  def create_server(name, type)
    neo.create_node("name" => name, "type" => type)
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

    @node = {:details_html => "<h2>Neo ID: #{node_id(node)}</h2>\n<p class='summary'>\n#{get_properties(node)}</p>\n",
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
