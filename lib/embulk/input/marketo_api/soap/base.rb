require "savon"
require "httpclient" # net/http can't verify cert correctly

module Embulk
  module Input
    module MarketoApi
      module Soap
        class Base
          attr_reader :endpoint, :wsdl, :user_id, :encryption_key

          RETRY_TIMEOUT_COUNT = 5

          def initialize(endpoint, wsdl, user_id, encryption_key)
            @endpoint = endpoint
            @wsdl = wsdl
            @user_id = user_id
            @encryption_key = encryption_key
          end

          private

          def savon
            headers = {
              'ns1:AuthenticationHeader' => {
                "mktowsUserId" => user_id,
              }.merge(signature)
            }
            # NOTE: Do not memoize this to use always fresh signature (avoid 20016 error)
            # ref. https://jira.talendforge.org/secure/attachmentzip/unzip/167201/49761%5B1%5D/Marketo%20Enterprise%20API%202%200.pdf (41 page)
            Savon.client(
              log: true,
              logger: Embulk.logger,
              wsdl: wsdl,
              soap_header: headers,
              endpoint: endpoint,
              open_timeout: 90,
              read_timeout: 90,
              raise_errors: true,
              namespace_identifier: :ns1,
              env_namespace: 'SOAP-ENV',
            )
          end

          def savon_call(operation, locals={})
            catch_unretryable_error do
              with_retry do
                savon.call(operation, locals.merge(advanced_typecasting: false))
              end
            end
          end

          def signature
            timestamp = Time.now.to_s
            encryption_string = timestamp + user_id
            digest = OpenSSL::Digest.new('sha1')
            hashed_signature = OpenSSL::HMAC.hexdigest(digest, encryption_key, encryption_string)
            {
              'requestTimestamp' => timestamp,
              'requestSignature' => hashed_signature.to_s
            }
          end

          def with_retry(&block)
            count = 0
            begin
              yield
            rescue ::Timeout::Error => e
              count += 1
              raise e if count > RETRY_TIMEOUT_COUNT
              Embulk.logger.warn "TimeoutError [#{count}/#{RETRY_TIMEOUT_COUNT}]. Retrying..."
              retry
            end
          end

          def catch_unretryable_error(&block)
            yield
          rescue Savon::SOAPFault => e
            Embulk.logger.debug "#{e.class}: #{e.to_hash}"
            if e.to_hash[:fault][:faultcode].to_str == "SOAP-ENV:Client"
              raise ConfigError, e.message
            end
          rescue Savon::HTTPError => e
            # NOTE: Marketo API always return error as HTTP 500
            # ref. https://jira.talendforge.org/secure/attachmentzip/unzip/167201/49761%5B1%5D/Marketo%20Enterprise%20API%202%200.pdf
            Embulk.logger.debug "#{e.class}: #{e.http.body}"
            soap_code = e.http.body[%r|<code>(.*?)</code>|, 1]
            soap_message = e.http.body[%r|<message>(.*?)</message>|, 1]
            case soap_code
            when "10001", "20011"
              # Internal Error
              raise e
            when "20015"
              # Request Limit Exceeded
              raise e
            else
              # unretryable error such as Authentication Failed, Invalid Request, etc.
              raise ConfigError, soap_message
            end
          rescue SocketError, Errno::ECONNREFUSED => e
            # maybe endpoint/wsdl domain was wrong
            Embulk.logger.debug "Connection error: endpoint=#{endpoint} wsdl=#{wsdl}"
            raise ConfigError, "Connection error: #{e.message} (endpoint is '#{endpoint}')"
          end
        end
      end
    end
  end
end
