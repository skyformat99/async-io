# Copyright, 2017, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require_relative 'socket'

require 'openssl'

module Async
	module IO
		SSLError = OpenSSL::SSL::SSLError
		
		# Asynchronous TCP socket wrapper.
		class SSLSocket < Generic
			wraps ::OpenSSL::SSL::SSLSocket, :alpn_protocol, :cert, :cipher, :client_ca, :context, :getsockopt, :hostname, :hostname=, :npn_protocol, :peer_cert, :peer_cert_chain, :pending, :post_connection_check, :setsockopt, :session, :session=, :session_reused?, :ssl_version, :state, :sync_close, :sync_close=, :sysclose, :verify_result, :tmp_key
			
			wrap_blocking_method :accept, :accept_nonblock
			wrap_blocking_method :connect, :connect_nonblock
			
			alias syswrite write
			alias sysread read
			
			def self.connect(socket, context, hostname = nil, &block)
				client = self.wrap(socket, context)
				
				# Used for SNI:
				if hostname
					client.hostname = hostname
				end
				
				begin
					client.connect
				rescue
					# If the connection fails (e.g. certificates are invalid), the caller never sees the socket, so we close it and raise the exception up the chain.
					client.close
					
					raise
				end
				
				return client unless block_given?
				
				begin
					yield client
				ensure
					client.close
				end
			end
			
			def local_address
				@io.to_io.local_address
			end
			
			def remote_address
				@io.to_io.remote_address
			end
			
			include Peer
			
			def self.wrap(socket, context)
				io = @wrapped_klass.new(socket.to_io, context)
				
				# We detach the socket from the reactor, otherwise it's possible to add the file descriptor to the selector twice, which is bad.
				socket.reactor = nil
				
				# This ensures that when the internal IO is closed, it also closes the internal socket:
				io.sync_close = true
				
				return self.new(io, socket.reactor)
			end
		end
		
		# We reimplement this from scratch because the native implementation doesn't expose the underlying server/context that we need to implement non-blocking accept.
		class SSLServer
			extend Forwardable
			
			def initialize(server, context)
				@server = server
				@context = context
			end
			
			def dup
				self.class.new(@server.dup, @context)
			end
			
			def_delegators :@server, :local_address, :setsockopt, :getsockopt, :close, :close_on_exec=, :reactor=
			
			attr :server
			attr :context
			
			def listen(*args)
				@server.listen(*args)
			end
			
			def accept(task: Task.current)
				peer, address = @server.accept
				
				wrapper = SSLSocket.wrap(peer, @context)
				
				return wrapper, address unless block_given?
				
				task.async do
					task.annotate "accepting secure connection #{address.inspect}"
					
					begin
						# You want to do this in a nested async task or you might suffer from head-of-line blocking.
						wrapper.accept
						
						yield wrapper, address
					rescue
						Async.logger.error(self) {$!}
					ensure
						wrapper.close
					end
				end
			end
			
			include Server
		end
	end
end
