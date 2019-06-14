# coding: utf-8

require 'kconv'

class IO
	def getc
		RUBY_VERSION < '1.9' ? super : self.read(1).ord
	end
end

#===============================================================================
#
#	Integer
#
class Integer

	#-----------------------------------------------------------
	#
	#	数値を人間に読みやすい表現形式で返す
	#
	def to_h(dot = false)
		unless((full = self.to_s).length > 3)
			full
		else
			case full.length % 3
				when 1 then top = full[0, 1] + (dot ? '.' + full[1, 1] : '')
				when 2 then top = full[0, 2]
				when 0 then top = full[0, 3]
			end
			top + '....KKKMMMGGGTTTPPP'[full.length].chr
		end
	end
end

#===============================================================================
#
#	String
#
class String

	if(RUBY_VERSION < '1.9')
		def ord
			self[0]
		end

		def force_encoding(encoding)
			self
		end
	end

	XFF = "\xFF".force_encoding('ASCII-8BIT')
	XFFFF = XFF * 2

	#-----------------------------------------------------------
	#
	#	キャラクタセットの定義
	#
	#		http://www.iana.org/assignments/character-sets
	#
	@@charsets = {
		'ISO-2022-JP'	=> Kconv::JIS,
		'SHIFT_JIS'		=> Kconv::SJIS,
		'SHIFT-JIS'		=> Kconv::SJIS,
		'EUC-JP'		=> Kconv::EUC,
		'UTF-8'			=> Kconv::UTF8,
	}

	def self.charset(charset)
		@@charsets[charset]
	end

	#-----------------------------------------------------------
	#
	#	メッセージヘッダのデコーダ
	#
	#		http://tools.ietf.org/html/rfc2047
	#
	@@decoders = {}
	@@current_decode_charset = 'UTF-8'

	def self.bind_decoder(code)
		@@decoders[code.upcase] = Proc.new
	end

	def self.set_decode_charset(charset)
		@@current_decode_charset = charset
	end

	def decode_mh												# decode message header
		gsub(/=\?([^?]+)\?(B|Q)\?([^?]+)\?=/i) {
			$3.decode_ec($2).decode_cs(@@current_decode_charset, $1)
		}.gsub(/[\x00-\x1F]/) {|c|
			'\x%02X' % c.ord
		}.encode(@@current_decode_charset, :invalid => :replace, :undef => :replace)
	end

	def decode_ec(code)											# decode encodings
		(it = @@decoders[code.upcase]) ? it.call(self) : self
	end

	def decode_cs(out_code, in_code)							# decode character sets
		(it = @@decoders[in_code.upcase]) ? it.call(self, out_code) : self.inspect
	end

	#-----------------------------------------------------------
	#
	#	メッセージヘッダのエンコーダ
	#
	#		http://tools.ietf.org/html/rfc2047
	#
	@@encoders = {}
	@@current_encode_charset = 'ISO-2022-JP'
#	@@current_encode_charset = 'UTF-8'
	@@current_encode_encoding = 'B'
#	@@current_encode_encoding = 'Q'

	def self.bind_encoder(code)
		@@encoders[code.upcase] = Proc.new
	end

	def self.set_encode_charset(charset)
		@@current_encode_charset = charset
	end
	def encode_mh_multi(field_name)								# encode message header multi line
		begin		
			(it = @@encoders[('<%s><%s><%s>' % ['MULTI', @@current_encode_charset, @@current_encode_encoding]).upcase]) ? it.call(self, field_name, Proc.new) : raise
		rescue
			field_name + ': ' + self.encode_mh
		end
	end
	def encode_mh												# encode message header
		"=?%s?%s?%s?=" % [@@current_encode_charset, @@current_encode_encoding,
			self.encode_cs(@@current_encode_charset, 'UTF-8').encode_ec(@@current_encode_encoding).chomp]
	end

	def encode_ec(code)											# encode encodings
		(it = @@encoders[code.upcase]) ? it.call(self) : self
	end

	def encode_cs(out_code, in_code)							# encode character sets
		decode_cs(out_code, in_code)
	end

	def encode_body(code)										# encode message body
		encode_cs(code, @@current_decode_charset)
	end

	#-----------------------------------------------------------
	#
	#	RFC 2231 拡張表現のエンコーダ
	#
	#		http://tools.ietf.org/html/rfc2231
	#
	@@rfc2231_encoders = {}
#	@@current_rfc2231_encode_charset = 'UTF-8'
	@@current_rfc2231_encode_charset = '<LEGACY><ISO-2022-JP><B>'

	def self.bind_rfc2231_encoder(code)
		@@rfc2231_encoders[code.upcase] = Proc.new
	end

	def self.set_rfc2231_encode_charset(charset)
		@@current_rfc2231_encode_charset = charset
	end

	def rfc2231_encode(attr, n = 78)
		@@rfc2231_encoders[@@current_rfc2231_encode_charset].call(self, attr, n, Proc.new)
	end

	#-----------------------------------------------------------
	#
	#	value のエンコーダ
	#
	def value_encode
		self =~ /[^-.0-9A-Z_]/i ? "\"#{self.gsub(/"/, '\"')}\"" : self
	end

	#-----------------------------------------------------------
	#
	#	ext-octet のデコーダ、エンコーダ
	#
	def ext_decode
		self.gsub(/%([0-9A-F]{2})/i) { $1.to_i(16).chr }
	end
	def ext_encode
		self.gsub(/[^-.0-9A-Z_]/i) {|c| '%%%02X' % c[0] }
	end

	#-----------------------------------------------------------
	#
	#	文字列を指定の長さに切り詰める
	#
	@@wsizer = {}
	@@centerer = {}
	@@snippers = {}
	@@each_snippers = {}
	@@current_snip_charset = 'UTF-8'
#	@@current_snip_charset = 'EUC-JP'
#	@@current_snip_charset = 'SHIFT_JIS'

	def self.bind_wsizer(charset)
		@@wsizer[charset] = Proc.new
	end

	def self.bind_centerer(charset)
		@@centerer[charset] = Proc.new
	end

	def self.bind_snipper(charset)
		@@snippers[charset] = Proc.new
	end

	def self.bind_each_snipper(charset)
		@@each_snippers[charset] = Proc.new
	end

	def self.set_snip_charset(charset)
		@@current_snip_charset = charset
	end

	def wsize
		@@wsizer[@@current_snip_charset].call(self)
	end

	def center(n, padding = ' ')
		@@centerer[@@current_snip_charset].call(self, n, padding)
	end

	def snip(n, charset = @@current_snip_charset)
		@@snippers[charset].call(self, n)
	end

	def each_snip(n, max = 9999)
		@@each_snippers[@@current_snip_charset].call(self, n, max, Proc.new)
	end

	#-----------------------------------------------------------
	#
	#	端末の UTF-8 対応の不備(記号の幅)を補う
	#
	#		http://ja.wikipedia.org/wiki/UTF-8
	#
	def enspc
#		return(self)											# UTF-8 以外ならコメントを生かす
		self.force_encoding('ASCII-8BIT').gsub(/[\xC0-\xE2][\x80-\xBF]+/n) {|c|	#### for UTF-8 いーかげん
			c + ' '
		}
	end

	#-----------------------------------------------------------
	#
	#	Re: をまとめる
	#
	def group_re(level = 0, re = 'Re')
		base = self.dup
		while(base =~ /^\s*#{re}\^?\d*:/i)
			base.sub!(/^\s*#{re}\^?(\d*):\s*/i) {
				level += ($1.to_i > 1 ? $1.to_i : 1)
				''
			}
		end
		(level < 1 ? '' : "#{re}: ") + base
#		(level < 1 ? '' : "#{re}#{level < 2 ? '' : "^#{level}"}: ") + base  # Re^3 表記
	end

	#-----------------------------------------------------------
	#
	#	Fw: をまとめる
	#
	def group_fw(level = 0)
		group_re(level, 'Fw')
	end

	#-----------------------------------------------------------
	#
	#	HTML の charset を返す
	#
	def html_charset
		(self =~ /"text\/html; charset=(.+)"/) ? $1 : nil
	end

	#-----------------------------------------------------------
	#
	#	HTML を UTF-8 に
	#
	def html_utf8
		(it = html_charset) ?
			self.encode('UTF-8', it, :invalid => :replace, :undef => :replace) :
			self.encode('UTF-8',     :invalid => :replace, :undef => :replace)
	end
end

#===============================================================================
#
#	多言語対応クラス
#
#		http://www.gnu.org/software/gettext/gettext.html
#
class Intl

	@@domains = {}
	@@domains[@@current_domain = 'default'] = {}

	def self.bind_text_domain(domain, dirname = '')
		load "#{dirname}#{domain}.pmo"
		@@domains[domain] = @@catalog
	end

	def self.set_text_domain(domain)
		@@current_domain = domain
	end

	def self.get_text(msgid)
		@@domains[@@current_domain][msgid] || msgid
	end
end

#===============================================================================
#
#	多言語対応
#
def _(msgid)
	Intl.get_text(msgid)
end

#===============================================================================
#
#	その他
#
def yap(arg = 'done.')
	@yap = 0 unless(@yap)
	print "#{@yap += 1}: #{arg.inspect}\n"
end

def debug(log = 'log.', obj = self)
	@debug = File.new('debug.log', 'a') and @debug.write('-' * 76 + "\n") unless(@debug)
	@debug.write(obj.to_s + ': ' + log.to_s + "\n")
end

#===============================================================================
#
#	各種デコーダ/エンコーダを登録
#
String.bind_decoder('7BIT') {|str|								# 7bit decoder
	str
}
String.bind_decoder('8BIT') {|str|								# 8bit decoder
	str
}
String.bind_decoder('BINARY') {|str, out_code|					# binary decoder?
#	'-- binary --'
	str.inspect
}
String.bind_decoder('BASE64') {|str|							# Base64 decoder
	str.unpack('m')[0]
}
String.bind_decoder('QUOTED-PRINTABLE') {|str|					# Quoted Printable decoder
	str.unpack('M')[0]
}
String.bind_decoder('B') {|str|									# Base64 decoder
	str.unpack('m')[0]
}
String.bind_encoder('B') {|str|									# Base64 encoder
	[str].pack('m999')
}
String.bind_decoder('Q') {|str|									# Quoted Printable decoder
	str.unpack('M')[0]
}
String.bind_encoder('Q') {|str|									# Quoted Printable encoder
	[str].pack('M999')
}
String.bind_encoder('<MULTI><ISO-2022-JP><B>') {|str, field_name, proc|	# encode message header multi line
	src = str + ' '; single_max = (max_length = 76) - (line = field_name + ': ').length
	while(src.length > 1)
		multi_max = ((single_max - 18) / 4 * 3 - 6) / 2
		if(single_max > 0 and src.force_encoding('ASCII-8BIT')  =~ /^([\x20-\x7E]{1,#{single_max}})[\x20\xC0-\xFD]/n)
			line += src.slice!(0, $1.length)
			single_max -= $1.length
		elsif(multi_max > 0 and src.force_encoding('ASCII-8BIT') =~ /^(([\xC0-\xFD][\x80-\xBF]+){1,#{multi_max}})/n)
			line += (line0 = src.slice!(0, $1.length).encode_mh)
			single_max -= line0.length
		else
			line == '' and raise
			proc.call(line.gsub(/^\t\s/, "\s")); line = "\t"; single_max = max_length
		end
	end
	proc.call(line.gsub(/^\t\s/, "\s"))
}
String.bind_encoder('<MULTI><UTF-8><B>') {|str, field_name, proc|	# encode message header multi line
	src = str + ' '; single_max = (max_length = 76) - (line = field_name + ': ').length
	while(src.length > 1)
		multi_max = (single_max - 12) / 4 * 3
		if(single_max > 0 and src.force_encoding('ASCII-8BIT') =~ /^([\x20-\x7E]{1,#{single_max}})[\x20\xC0-\xFD]/n)
			line += src.slice!(0, $1.length)
			single_max -= $1.length
		elsif(multi_max > 0 and src.force_encoding('ASCII-8BIT') =~ /^([\x80-\xFD]{1,#{multi_max}})[\x20-\x7E\xC0-\xFD]/n)
			line += (line0 = src.slice!(0, $1.length).encode_mh)
			single_max -= line0.length
		else
			line == '' and raise
			proc.call(line.gsub(/^\t\s/, "\s")); line = "\t"; single_max = max_length
		end
	end
	proc.call(line.gsub(/^\t\s/, "\s"))
}
String.bind_decoder('US-ASCII') {|str, out_code|				# us-ascii decoder
	str
}
String.bind_decoder('ISO-8859-1') {|str, out_code|				# iso-8859-1 decoder
	str
}
String.bind_decoder('ISO-2022-JP') {|str, out_code|				# iso-2022-jp decoder
	str.kconv(String.charset(out_code), Kconv::JIS)
}
String.bind_decoder('ISO-2022-JP-1') {|str, out_code|			# iso-2022-jp-1 decoder
	str.kconv(String.charset(out_code), Kconv::JIS)
}
String.bind_decoder('ISO-2022-JP-2') {|str, out_code|			# iso-2022-jp-2 decoder
	str.kconv(String.charset(out_code), Kconv::JIS)
}
String.bind_decoder('SHIFT_JIS') {|str, out_code|				# shift_jis decoder
	str.kconv(String.charset(out_code), Kconv::SJIS)
}
String.bind_decoder('SHIFT-JIS') {|str, out_code|				# shift_jis decoder
	str.kconv(String.charset(out_code), Kconv::SJIS)
}
String.bind_decoder('EUC-JP') {|str, out_code|					# euc-jp decoder
	str.kconv(String.charset(out_code), Kconv::EUC)
}
String.bind_decoder('UTF-8') {|str, out_code|					# utf-8 decoder
	str.kconv(String.charset(out_code), Kconv::UTF8)
}
#	http://tools.ietf.org/html/rfc2152
String.bind_decoder('UTF-7') {|str, out_code|					# utf-7 decoder
	str.gsub(%r|\+([A-Za-z0-9+/]+)-?|) {|p|
		($1 + '==').unpack('m')[0].kconv(Kconv::UTF8, Kconv::UTF16)
	}.gsub(/\+-/, '+').kconv(String.charset(out_code), Kconv::UTF8)
}

# 11bit: 0xC0-0xDF 0x80-0xBF
# 16bit: 0xE0-0xEF 0x80-0xBF 0x80-0xBF
# 21bit: 0xF0-0xF7 0x80-0xBF 0x80-0xBF 0x80-0xBF
# 26bit: 0xF8-0xFB 0x80-0xBF 0x80-0xBF 0x80-0xBF 0x80-0xBF
# 31bit: 0xFC-0xFD 0x80-0xBF 0x80-0xBF 0x80-0xBF 0x80-0xBF 0x80-0xBF

String.bind_wsizer('UTF-8') {|str|								# 表示幅を得る
	str.force_encoding('ASCII-8BIT').gsub(/[\xC0-\xFD][\x80-\xBF]+/n, "\xFF\xFF").length
}

String.bind_centerer('UTF-8') {|str, n, padding|				# センタリングする
	w = n - str.wsize
	w = 0 if(w < 0)
	(padding * (w >> 1) + str + padding * w).snip(n)
}

String.bind_snipper('UTF-8') {|str, n|							# 指定の長さに切り詰める
	str.force_encoding('ASCII-8BIT')
	ws = str[0, n * 2].gsub(/[\xC0-\xFD][\x80-\xBF]+/n, String::XFFFF)[0, n]
	wc = ws.count(String::XFF)
	str.slice(0, n + wc / 2 - wc % 2) + ' ' * (n - ws.length + wc % 2)	# ASCII-8BIT で返す
}

String.bind_each_snipper('UTF-8') {|str, n, max, proc|			# 指定の長さに切り詰め、順に行を渡す
	str.force_encoding('ASCII-8BIT')
	p = 0; while(p <= str.length)								# '<': 改行文字のみの行は省略
		break if((max -= 1) < 0)
		ws = str[p, n * 2].gsub(/[\xC0-\xFD][\x80-\xBF]+/n, String::XFFFF)[0, n]
		wc = ws.count(String::XFF)
		proc.call(str.slice(p, nn = n + wc / 2 - wc % 2) + ' ' * (n - ws.length + wc % 2))
		p += nn
	end
}

String.bind_rfc2231_encoder('UTF-8') {|str, attr, n, proc|		# RFC 2231 拡張表現にエンコードして返す(添付ファイル名指定用)
	multi = false; head = ''; str.force_encoding('ASCII-8BIT') =~ /[\xC0-\xFD]/n and multi = true and head = "utf8''"
	w = n - attr.size - "\t*n*=;".size - head.size
	nth = -1; nl = ''; el = ''; str.gsub(/./u) {|nc|
		multi = true if(!multi and nc.force_encoding('ASCII-8BIT') =~ /[\xC0-\xFD]/n)
		if(lnl = nl and lel = el and nl += nc and (el += (ec = nc.ext_encode)).size > w)
			proc.call("\t%s*%d%s=%s%s;" % [attr, nth += 1, multi ? '*' : '', head, multi ? lel : lnl.value_encode])
			multi = false; head = ''
			w = n - attr.size - "\t*n*=;".size - head.size
			nl = nc; el = ec
		end
	}
	proc.call("\t%s%s%s=%s%s" % [attr, nth == -1 ? '' : "*#{(nth += 1).to_s}", multi ? '*': '', head, multi ? el : nl.value_encode])
}

String.bind_rfc2231_encoder('<LEGACY><ISO-2022-JP><B>') {|str, attr, n, proc|	# RFC 違反だが B encoding でエンコードして返す(添付ファイル名指定用)
	proc.call("\t%s=\"=?%s?%s?%s?=\"" % [attr, 'ISO-2022-JP', 'B', str.encode_cs('ISO-2022-JP', 'UTF-8').encode_ec('B').chomp])
}

#     漢字: 0xA1-0xFE 0xA1-0xFE
# 半角カナ: 0x8E 0xA1-0xDF	
# 補助漢字: 0x8F 0xA1-0xFE 0xA1-0xFE

String.bind_wsizer('EUC-JP') {|str|								# 表示幅を得る
	str.force_encoding('ASCII-8BIT').gsub(/[\xA1-\xFE][\xA1-\xFE]/n, "\xFF\xFF").length
}

String.bind_centerer('EUC-JP') {|str, n, padding|				# センタリングする
	w = n - str.wsize
	w = 0 if(w < 0)
	(padding * (w >> 1) + str + padding * w).snip(n)
}

String.bind_snipper('EUC-JP') {|str, n|							#### 指定の長さに切り詰める
	str.force_encoding('ASCII-8BIT')
	ws = str[0, n * 2].gsub(/[\xA1-\xFE][\xA1-\xFE]/n, String::XFFFF)[0, n]
	wc = ws.count(String::XFF)
	str.slice(0, n - wc % 2) + ' ' * (n - ws.length + wc % 2)
}

String.bind_each_snipper('EUC-JP') {|str, n, max, proc|			#### 指定の長さに切り詰め、順に行を渡す
	str.force_encoding('ASCII-8BIT')
	p = 0; while(p <= str.length)								# '<': 改行文字のみの行は省略
		break if((max -= 1) < 0)
		ws = str[p, n * 2].gsub(/[\xA1-\xFE][\xA1-\xFE]/n, String::XFFFF)[0, n]
		wc = ws.count(String::XFF)
		proc.call(str.slice(p, nn = n - wc % 2) + ' ' * (n - ws.length + wc % 2))
		p += nn
	end
}

#### TAB 対応

__END__

