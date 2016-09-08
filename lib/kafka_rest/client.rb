require 'net/http'
require 'json'

module KafkaRest
  class Client
    attr_reader :endpoint, :username, :password, :host

    def initialize(endpoint, username = nil, password = nil, host = nil)
      @endpoint = URI(endpoint)
      @username, @password = username, password
      @host = host
    end

    def topic(name)
      KafkaRest::Topic.new(self, name)
    end

    def topics
      request(:get, '/topics').inject({}) do |result, topic|
        result[topic] = KafkaRest::Topic.new(self, topic)
        result
      end
    end

    def brokers
      request(:get, '/brokers')[:brokers]
    end

    def consumer(group, options = {})
      KafkaRest::Consumer.new(self, group, options)
    end

    def http
      @http ||= begin
        http = Net::HTTP.new(endpoint.host, endpoint.port)
        http.use_ssl = endpoint.scheme == 'https'
        http
      end
    end

    def close
      finish if http.started?
    end

    def request(method, path, body: nil, content_type: nil, accept: nil)
      request_class = case method
        when :get;    Net::HTTP::Get
        when :post;   Net::HTTP::Post
        when :put;    Net::HTTP::Put
        when :delete; Net::HTTP::Delete
        else raise ArgumentError, "Unsupported request method"
      end

      request = request_class.new(path)
      request['Accept'.freeze] = accept || DEFAULT_ACCEPT_HEADER
      request['Content-Type'.freeze] = content_type || DEFAULT_CONTENT_TYPE_HEADER
      request['Host'.freeze] = host if host
      request.basic_auth(username, password) if username && password
      request.body = JSON.dump(body) if body

      case response = http.request(request)
      when Net::HTTPSuccess
        begin
          if response.body
            JSON.parse(response.body, symbolize_names: true)
          else
            {}
          end
        rescue JSON::ParserError => e
          raise KafkaRest::InvalidResponse, "Invalid JSON in response: #{e.message}"
        end

      when Net::HTTPForbidden
        message = username.nil? ? "Unauthorized" : "User `#{username}` failed to authenticate"
        raise KafkaRest::UnauthorizedRequest.new(response.code.to_i, message)

      else
        response_data = begin
          JSON.parse(response.body, symbolize_names: true)
        rescue JSON::ParserError => e
          raise KafkaRest::InvalidResponse, "Invalid JSON in response: #{e.message}"
        end

        error_class = RESPONSE_ERROR_CODES[response_data[:error_code]] || KafkaRest::ResponseError
        raise error_class.new(response_data[:error_code], response_data[:message])
      end
    end

    def self.open(endpoint, **kwargs, &block)
      client = new(endpoint, **kwargs)
      block.call(client)
    ensure
      client.close
    end

    BINARY_MESSAGE_CONTENT_TYPE = "application/vnd.kafka.binary.v1+json".freeze
    AVRO_MESSAGE_CONTENT_TYPE   = "application/vnd.kafka.avro.v1+json".freeze
    JSON_MESSAGE_CONTENT_TYPE   = "application/vnd.kafka.json.v1+json".freeze

    JSON_REQUEST_CONTENT_TYPE   = "application/vnd.kafka.v1+json"

    DEFAULT_ACCEPT_HEADER = JSON_REQUEST_CONTENT_TYPE
    DEFAULT_CONTENT_TYPE_HEADER = JSON_REQUEST_CONTENT_TYPE
    private_constant :DEFAULT_CONTENT_TYPE_HEADER, :DEFAULT_ACCEPT_HEADER
  end
end
