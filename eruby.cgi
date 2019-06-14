#!/usr/bin/env ruby

require 'erb'
#require 'cgi'

begin
	Dir.chdir(File.dirname(rhtml = ENV['PATH_TRANSLATED']))
	print 'Content-Type: text/html; charset=UTF-8', $/, $/
	ERB.new(File.read(rhtml).force_encoding('UTF-8')).run
rescue
	print <<ERR
<H1>Script Error</H1>
<PRE>#{CGI.escapeHTML($!.message)}</PRE>
<H2>Backtrace</H2>
<PRE>#{CGI.escapeHTML($!.backtrace.join($/))}</PRE>
ERR
end
