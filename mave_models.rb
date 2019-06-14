# coding: utf-8

require './xdbm'
require 'time'
require 'net/pop'
require 'net/smtp'
require 'digest/md5'

#===============================================================================
#
#	ショートカットキークラス
#
class MaveShortcuts

	@@rsv = 'zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA9876543210'

	def initialize
		@fw = Hash.new
		@rv = Hash.new
	end

	def assign(hint, instance)
		hint.gsub(/[^0-9A-Z]/i, '').concat(@@rsv).each_byte {|key|
			@rv[(@fw[key] = instance).object_id] = key and break unless(@fw[key])
		}
	end

	def [](param)
		param.is_a?(Integer) ? @fw[param] : @rv[param.object_id]
	end

	def release(instance)
		@fw.delete(self[instance])
		@rv.delete(instance.object_id)
	end
end

#===============================================================================
#
#	連番処理付き XDBM クラス
#
class SqXDBM < XDBM

	@@start = 100
	@@sym = '#last#'

	def initialize(*params)
		super
		self[@@sym] ||= @@start.to_s
	end

	#-----------------------------------------------------------
	#
	#	最後の連番を返す
	#
	def last_sq
		self[@@sym]
	end

	#-----------------------------------------------------------
	#
	#	加算した連番を返す
	#
	def inc_sq
		self[@@sym] = (self[@@sym].to_i + 1).to_s
	end
end

#===============================================================================
#
#	フラグ処理/メール総数管理用 XDBM クラス
#
class FlagXDBM < XDBM

	@@n_mail_sym = '#n_mail#'									# メール総数

	def initialize(*params)
		@alloc_pos = -1
		@pos_flag = {}
		@max_flags = 32
		@default = ?-
		super
	end

	def alloc_flag(flag)
		@pos_flag[flag] ||= @alloc_pos += 1 
	end

	def set_flag(key, flag, pattern)
		flags = self[key] ||= @default.chr * @max_flags
		flags[@pos_flag[flag]] = pattern
		self[key] = flags
	end

	def get_flag(key, flag)
		self[key] ? self[key][@pos_flag[flag]] : @default
	end

	def set_flags(key, flags)
		self[key] = flags
	end

	def get_flags(key)
		self[key] ||= @default.chr * @max_flags
	end

	def get_n(sym = @@n_mail_sym)
		self[sym]
	end

	def set_n(sym = @@n_mail_sym, n = 0)
		self[sym] = n.to_s
	end
	alias :reset_n :set_n

	def n_is_zero?(sym = @@n_mail_sym)
		self[sym] == '0'
	end

	def inc_n(sym = @@n_mail_sym)
		self[sym] = (self[sym].to_i + 1).to_s
	end

	def dec_n(sym = @@n_mail_sym)
		self[sym] = (self[sym].to_i - 1).to_s
	end
end

#===============================================================================
#
#	モデルが自分の関連ビューを管理するクラス
#
class MaveModelViews < Hash

	def initialize
		@sq = 0
	end

	def []=(name, view)
		super(name || (@sq += 1).to_s, view)
	end

	def update													# モデル側の更新を契機として自発的に
		each {|key, value|
			value.update										# キー操作とは非同期にビューを再描画
		}
	end
end

#===============================================================================
#
#	モデルベースクラス
#
class MaveBaseModel

	def initialize(params)
		@configs = params[:CONFIGS]
		@views = MaveModelViews.new
		@clean = 0; @dirty = 1									# 情報更新の有無の管理
	end

	def tie(view, name = nil)
		@views[name] = view
	end

	def dirty
		@dirty += 1
	end

	def dirty?
		@clean < @dirty and @clean = @dirty
	end

	def aplname
		@configs[:APLNAME]
	end
end

#===============================================================================
#
#	メールアカウントモデルクラス
#
class MaveAccount < MaveBaseModel

	attr_reader :name
	attr_reader :enable
	attr_reader :pop_server
	attr_reader :mail_from
	attr_reader :smtp_server
	attr_reader :import_command
	attr_reader :hash_id

	def initialize(params)
		super
		@account		= params[:ACCOUNT]

		@name			= @account[:NAME]
		@enable			= @account[:ENABLE]

		@pop_server		= @account[:POP_SERVER]
		@pop_port		= @account[:POP_PORT]
		@pop_account	= @account[:POP_ACCOUNT]
		@pop_password	= @account[:POP_PASSWORD]
		@pop_over_ssl	= @account[:POP_OVER_SSL]
		@pop_ssl_verify	= @account[:POP_SSL_VERIFY]
		@pop_ssl_certs	= @account[:POP_SSL_CERTS]
		@pop_keep_time	= @account[:POP_KEEP_TIME]

		@mail_from		= @account[:USER_ADDRESS]

		@smtp_server	= @account[:SMTP_SERVER]
		@smtp_port		= @account[:SMTP_PORT]
		@smtp_helo		= @account[:SMTP_HELO]
		@smtp_account	= @account[:SMTP_ACCOUNT]
		@smtp_password	= @account[:SMTP_PASSWORD]
		@smtp_authtype	= @account[:SMTP_AUTHTYPE]
		@smtp_over_tls	= @account[:SMTP_OVER_TLS]
		@smtp_tls_verify= @account[:SMTP_TLS_VERIFY]
		@smtp_tls_certs	= @account[:SMTP_TLS_CERTS]

		@import_command	= @account[:IMPORT_COMMAND]

		@hash_id		= Digest::MD5.hexdigest(@account[:USER_ADDRESS])[0, 8]
		@pop_uids		=     XDBM.new(@configs[:ROOT_DIRECTORY] + "/pop_uids_#{name}", 0600)
	end

	#-----------------------------------------------------------
	#
	#	アカウントの各要素を返す
	#
	def [](param)
		@account[param]
	end

	#-----------------------------------------------------------
	#
	#	POP する
	#
	def pop
		now = Time.new.to_i
		begin
			pop = Net::POP3.new(@pop_server, @pop_port)
			pop.enable_ssl(@pop_ssl_verify, @pop_ssl_certs) if(@pop_over_ssl)
			pop.start(@pop_account, @pop_password) {|pop|
				yield(_('Connected.'))
				popmails = []
				pop.mails.each {|popmail|
					if(it = @pop_uids[popmail.unique_id])		# 既知のメール
						if(it.to_i < now - @pop_keep_time)
							popmail.delete
							@pop_uids.delete(popmail.unique_id)
						end
					else										# 未知のメール
						popmails << popmail
					end
				}
				yield(popmails.size)
				popmails.each {|popmail|
					yield(popmail)
					@pop_uids[popmail.unique_id] = now.to_s
					@dirty += 1
				}
				@pop_uids.keys.each {|unique_id|
					@pop_uids.delete(unique_id) if(@pop_uids[unique_id].to_i < now - @pop_keep_time)
				}
			} if(@pop_server)
		rescue StandardError, Timeout::Error
			raise($!.message.split(/\r?\n/)[0])
		end
	end

	#-----------------------------------------------------------
	#
	#	SMTP する
	#
	def smtp
		begin
			smtp = Net::SMTP.new(@smtp_server, @smtp_port)
			if(@smtp_over_tls)
				ssl = OpenSSL::SSL::SSLContext.new
				(it = @smtp_tls_verify) and ssl.verify_mode = it
				(it = @smtp_tls_certs)  and ssl.ca_file     = it
				smtp.enable_tls(ssl)
			end
			smtp.start(@smtp_helo, @smtp_account, @smtp_password, @smtp_authtype) {|smtp|
				yield(_('Connected.'))
				yield(smtp)
			} if(@smtp_server)
		rescue StandardError, Timeout::Error
			raise($!.message.split(/\r?\n/)[0])
		end
	end

	def close
		@pop_uids.reorganize;		@pop_uids.close
	end
end

#===============================================================================
#
#	メールアカウント「群」モデルクラス
#
class MaveAccounts < MaveBaseModel

	def initialize(params)
		super
		@accounts		= {}

		@regular_nth = nil
		@configs[:ACCOUNTS].each_index {|nth|
			it = @accounts[@configs[:ACCOUNTS][nth][:NAME]] = MaveAccount.new({:CONFIGS => @configs, :ACCOUNT => @configs[:ACCOUNTS][nth]})
			@regular_nth = nth if(!@regular_nth and it.enable)
		}
		unless(@regular_nth)
			print "#{_('Prepare one or more enable accounts [mave.config].').decode_cs(@configs[:TERMINAL_CHARSET], 'UTF-8')}\n"
			exit
		end
	end

	#-----------------------------------------------------------
	#
	#	メールアカウントを順に渡す
	#
	def each(all = false)										#### 適切な順序で返すようにする
		@accounts.each {|name, account|
			yield(account) if(account.enable or all)
		}
	end

	#-----------------------------------------------------------
	#
	#	既定のメールアカウントを返す／変更する
	#
	def regular
		@accounts[@configs[:ACCOUNTS][@regular_nth][:NAME]]
	end

	def previous
		begin
			@regular_nth -= 1; @regular_nth %= @configs[:ACCOUNTS].size
		end until(@accounts[@configs[:ACCOUNTS][@regular_nth][:NAME]].enable)
		regular
	end

	def next
		begin
			@regular_nth += 1; @regular_nth %= @configs[:ACCOUNTS].size
		end until(@accounts[@configs[:ACCOUNTS][@regular_nth][:NAME]].enable)
		regular
	end

	#-----------------------------------------------------------
	#
	#	指定のメールアカウントを返す
	#
	def [](name)
		@accounts[name]
	end

	def close
		each(all = true) {|account| account.close }
	end
end

#===============================================================================
#
#	ディレクトリモデルクラス
#
class MaveDirectory < MaveBaseModel

	attr_reader :path											# ディレクトリの絶対パス

	def initialize(params)
		super
		@path			= params[:PATH]

		@cluster_dirs	= @configs[:CLUSTER_DIRS]
		@cluster_ext	= @configs[:CLUSTER_EXT]

		unless(File.directory?(@path))							# (クラスタ)ディレクトリ作成
			Dir.mkdir(@path, 0700)
			(0...@cluster_dirs).each {|nth|
				Dir.mkdir('%s/%04d.%s' % [@path, nth, @cluster_ext], 0700)
			} unless(@path == params[:CONFIGS][:POP_DIRECTORY])
		end

		@cluster_paths	= []									# クラスタディレクトリ認識
		Dir.glob(@path + '/*.' + @cluster_ext) {|dir|
			@cluster_paths << File.basename(dir) + '/'
		}
		@cluster_paths << '' if(@cluster_paths.empty?)

		xdbm_flags		= params[:CONFIGS][:XDBM_FLAGS]
		@filename_sq	=   SqXDBM.new(@path + '/filename_sq',	0600, xdbm_flags)	# ベースファイル名<-メール連番
	end

	#---------------------------------------- MaveDirectory ----
	#
	#	メールファイルをディレクトリ内に新規作成
	#
	def create_mailfile
		halfname = '%s%08d.eml' % [@cluster_paths[(it = @filename_sq.inc_sq.to_i) % @cluster_paths.size], it]
		File.open(@path + '/' + halfname, 'w', 0600) {|fh|
			yield(fh)
		}
		@dirty += 1
		halfname
	end

	#-----------------------------------------------------------
	#
	#	任意の内容のメールファイルをディレクトリ内に新規作成
	#
	def generate_mailfile(header, heads, lines, account)
		halfname = create_mailfile {|fh|
			MavePseudoMail.new({:CONFIGS => @configs, :MODE => :NEW, :ACCOUNT => account}).header_each {|line|
				if(line =~ /^Subject: /)
					fh.write("Subject: %s\n" % (header['Subject'] || '*Shell Command Output*'))	####
				elsif(line =~ /^(.+): / and it = header[$1.capitalize])
					fh.write("#{$1}: #{it}\n")
				else
					fh.write(line + "\n")
				end
			}
			header.each {|k, v|
				k =~ /^X-Mave-/ and fh.write("#{k}: #{v}\n")
			}
			fh.write("\n")
			heads.each {|line|
				fh.write(line.chomp + "\n")
			}
			lines.each {|line|
				fh.write(line.chomp + "\n")
			}
		}
	end

	#---------------------------------------- MaveDirectory ----
	#
	#	メールファイルを上書き
	#
	def overwrite_mailfile(halfname)
		File.open(@path + '/' + halfname, 'w', 0600) {|fh|
			yield(fh)
		}
		@dirty += 1
		halfname
	end

	#---------------------------------------- MaveDirectory ----
	#
	#	メールファイルのハッシュ値を返す
	#
	def md5(halfname)
		Digest::MD5.file(@path + '/' + halfname).to_s
	end

	#---------------------------------------- MaveDirectory ----
	#
	#	メールファイルを削除
	#
	def delete(halfname)
		File.delete(@path + '/' + halfname) unless(RUBY_PLATFORM =~ /i.86-mswin32/)	####
		@dirty += 1
	end

	#---------------------------------------- MaveDirectory ----
	#
	#	関連ディレクトリを返す
	#
	def related_path0
		@path + '/attachments'
	end
	def related_path(unique_name)
		related_path0 + '/' + unique_name
	end

	#---------------------------------------- MaveDirectory ----
	#
	#	ディレクトリ内に関連ディレクトリを生成する
	#
	def make_related_directory(unique_name)
		dirname0 = related_path0
		Dir.mkdir(dirname0, 0700) unless(File.directory?(dirname0))
		dirname  = related_path(unique_name)
		Dir.mkdir(dirname,  0700) unless(File.directory?(dirname))
		dirname
	end

	#---------------------------------------- MaveDirectory ----
	#
	#	関連ディレクトリ内に、新規に関連ファイルを作成する
	#	関連ディレクトリ内に、添付ファイルを展開する
	#
	def create_new_relation(unique_name, filename, part = nil)
		filename = make_related_directory(unique_name) + '/' + filename
		return(false) if(File.file?(filename))					# 既に存在しているなら上書きはしない
		File.open(filename, 'w', 0600) {|fh|
			part.dump {|line|
				fh.write(line)
			} if(part)
		}
		filename
	end
	alias :extract_attachment :create_new_relation

	#---------------------------------------- MaveDirectory ----
	#
	#	関連ディレクトリ内に存在するファイルを返す
	#
	def related_files(unique_name)
		path = related_path(unique_name)
		filenames = []; Dir.foreach(path) {|filename|
			filenames << filename unless(filename =~ /^\./)
		} if(File.directory?(path))
		filenames
	end

	#---------------------------------------- MaveDirectory ----
	#
	#	関連ディレクトリを移動／削除する
	#
	def move_related_directory(unique_name, to_dir)
		from = related_path(unique_name)
		if(to_dir)
			to0  = to_dir.related_path0
			to   = to_dir.related_path(unique_name)
			Dir.mkdir(to0, 0700) unless(File.directory?(to0))
			File.rename(from, to) if(File.directory?(from) and !File.exist?(to))
		else													# to_dir が nil なら削除
			#### 再帰的に削除
		end
	end

	#---------------------------------------- MaveDirectory ----
	#
	#	最後の連番を返す
	#
	def last_sq
		@filename_sq.last_sq
	end

	def close
		@filename_sq.reorganize;	@filename_sq.close
	end
end

#===============================================================================
#
#	メールフォルダモデルクラス
#
class MaveFolder < MaveDirectory

	attr_reader :name											# フォルダの名前
	attr_reader	:flags_sq
	attr_reader	:sq_subjectid									#### subject_id debug
	attr_reader	:wiki_configs									#### maverick debug

	@@debug_what_scache = false

	#--------------------------------------------- MaveFolder ----
	#
	#	メールの概要キャッシュ(インクリメンタルサーチ用)表示、切り替え(デバッグ用)
	#
	def self.toggle_what_scache
		@@debug_what_scache = !@@debug_what_scache
	end

	def initialize(params)
		params[:PATH]	= params[:CONFIGS][:ROOT_DIRECTORY] + '/' + params[:NAME]
		super
		@name			= params[:NAME]

		xdbm_flags		= params[:CONFIGS][:XDBM_FLAGS]
		@sq_rootsq		=   SqXDBM.new(@path + '/sq_rootsq',	0600, xdbm_flags)	# メール連番<-最新順ルート連番

		@messageid_sq	=     XDBM.new(@path + '/messageid_sq',	0600, xdbm_flags)	# メッセージID<-メール連番
		@sq_messageid	=     XDBM.new(@path + '/sq_messageid',	0600, xdbm_flags)	# メール連番<-メッセージID
		@sq_subjectid	=     XDBM.new(@path + '/sq_subjectid', 0600, xdbm_flags)	# メール連番<-サブジェクトID

		@rootsq_sq		=     XDBM.new(@path + '/rootsq_sq',	0600, xdbm_flags)	# ルートメール連番<-メール連番
		@parentsq_sq	=     XDBM.new(@path + '/parentsq_sq',	0600, xdbm_flags)	# 親メール連番<-メール連番
		@childsqs_sq	=     XDBM.new(@path + '/childsqs_sq',	0600, xdbm_flags)	# 子メール連番群<-メール連番	#### 統合不可？

		@abstract_sq	=     XDBM.new(@path + '/abstract_sq',	0600, xdbm_flags)	# メール概要<-メール連番
		@flags_sq		= FlagXDBM.new(@path + '/flags_sq',		0600, xdbm_flags)	# 各種フラグ群<-メール連番
		[:RED, :FLAG, :NOTICE, :FOLD, :TOYOU].each {|flag|
			@flags_sq.alloc_flag(flag)
		}
		@flags_sq.get_n				|| @flags_sq.reset_n				# メール総数
		@flags_sq.get_n('#r_mail#')	|| @flags_sq.reset_n('#r_mail#')	# 既読メール総数
		@flags_sq.get_n('#unred#')	|| @flags_sq.reset_n('#unred#')		# フォルダに未読メールあり

		# フォルダの設定ファイルを読む(folder_configs プロパティと、bind? メソッドが追加される)
		begin
			unless(File.exist?(config_filename))	####
				fr = File.open('mave.folderconfig.master')
				File.open(config_filename, 'w', 0600) {|fw| fw.write(fr.read) }
			end
			File.open('mave.folderconfig.common') {|fh| instance_eval(fh.read) }
			File.open(config_filename) {|fh| instance_eval(fh.read) }
		rescue													# 設定ファイルが読めなければ適当に
			@folder_configs = {}
			@folder_configs[:LIST_NAME] = @name
			@folder_configs[:LIST_PRIORITY] = 50
			@folder_configs[:BIND_PRIORITY] = 50
			def bind?(mail, account)
				@name == account[:INBOX_FOLDER]
			end
		end
	end

	def config_filename
		@path + '/mave.folderconfig'
	end

	def configs
		@folder_configs
	end

	def md5
		Digest::MD5.file(config_filename).to_s
	end

	#------------------------------------------- MaveFolder ----
	#
	#	指定のメール連番のメールインスタンスを返す
	#
	def get_mail(sq)
		sq ? MaveMail.new({:CONFIGS => @configs, :FILE => File.new(@path + '/' + @filename_sq[sq]), :FOLDER => self, :SQ => sq}) : nil
	end
	def get_mail_by_message_id(message_id)
		message_id and get_mail(@sq_messageid[message_id])
	end

	#------------------------------------------- MaveFolder ----
	#
	#	関連するメール連番を返す
	#
	def get_sq_by_message_id(message_id)
		@sq_messageid[message_id]
	end
	def get_rootsq_by_sq(sq)
		@rootsq_sq[sq]
	end

	#------------------------------------------- MaveFolder ----
	#
	#	メールの概要を内部コーディング(UTF-8)で返す
	#
	def abstract_of_mail(sq, mail, marks = {}, padding = '')
		@@debug_what_scache and @abstract_sq[sq] and return(abstract_of_mail_for_search(sq, nil, marks))
		'%s%c%c %3d %s %s %4s %c%s %s%c%s' % [
			marks.size == 0 ? '' : (marks[sq] ? 'M ' : '- '),
			red?(sq) ? ?. : ?x,
			notice?(sq) ? ?# : (flag?(sq) ? ?F : ?.),
			(it = last_sq.to_i - sq.to_i) < 1000 ? it : 999,
			('%-*s' % [fw = 16, (@folder_configs[:SEND_VIEW] ? (mail.pseudo_to ? mail.pseudo_to.snip(fw, 'UTF-8') : '-') : (mail.pseudo_from ? mail.pseudo_from.snip(fw, 'UTF-8') : '-')).force_encoding('ASCII-8BIT')]).force_encoding('UTF-8'),
			('%*s' % [dw = Time.mystrftime_len, (mail.date ? mail.date.mystrftime : '-' * dw).force_encoding('ASCII-8BIT')]).force_encoding('UTF-8'),
			mail.size.to_h,
			'.vw'[toyou?(sq)],
			mail.multipart? ? '@' : '.',
			padding,
			'#+=-'[(padding == '' ? 0 : 2) + (fold?(sq) ? 0 : 1)],
			mail.subject.decode_mh,
		]
	end

	#------------------------------------------- MaveFolder ----
	#
	#	メールの概要キャッシュ(インクリメンタルサーチ用)を返す
	#
	def abstract_of_mail_for_search(sq, dummy = nil, marks = {})
		'%s%c%c %3d %s' % [
			marks.size == 0 ? '' : (marks[sq] ? 'M ' : '- '),
			red?(sq) ? ?. : ?x,
			notice?(sq) ? ?# : (flag?(sq) ? ?F : ?.),
			(it = last_sq.to_i - sq.to_i) < 1000 ? it : 999,
			@abstract_sq[sq] || (@abstract_sq[sq] = abstract_of_mail_for_search_cache(sq, get_mail(sq))),
		]
	end
	def abstract_of_mail_for_search_cache(sq, mail)
		pseudo = @folder_configs[:SEND_VIEW] ? mail.pseudo_to : mail.pseudo_from
		'%s %s %c%s %s %s' % [
			mail.date ? mail.date.mystrftime(false) : '-',		#### 日付を数字で持っておく手もある
			mail.size.to_h,
			'.vw'[toyou?(sq)],
			mail.multipart? ? '@' : '.',
			(it = phoneticize('%s %s' % [pseudo, mail.subject.decode_mh])) ? it : '',	# 文字列の読み(ローマ字)表記
			mail.subject.decode_mh,
		]
	end
	def delete_abstract(sq)
		@abstract_sq.delete(sq)									# メール概要を消す
	end

	#------------------------------------------- MaveFolder ----
	#
	#	メール DB のリンク構造
	#
	#						(@sq_rootsq)
	#
	#			+----------->[9]---->[5]--------+
	#			|								|
	#			|	+------->[8]---->[7]----+	|
	#			|	|						|	|
	#			|	|	+--->x7x---->x5x----- x |					root ..	(@rootsq_sq)
	#			|	|	|					|	|		+---+<--+<--+
	#			|	|	x					|	|		v	|	|	|
	#			+-------------------------------+----->[5]--+	|	|
	#		parent	|						|			^		|	|
	#				|						|			+--[6]--+	|
	#				|						|		parent	^		|
	#				|						|				+--[8]--+
	#				|						|				^		|
	#				|						|				+--[9]--+
	#				|						|			parent ............	(@parentsq_sq)
	#				|						|
	#				|						|				root
	#				|						|			+---+
	#				|						|			v	|
	#				+-----------------------+--------->[7]--+
	#			parent

	#------------------------------------------- MaveFolder ----
	#
	#	メールのスレッド関係の操作(結合、独立、再結合)
	#
	#		#### マークした折り畳み中のスレッドを結合する場合の扱い
	#
	def join_mail(sq, parent_sq)
		(pp_sq = parent_sq) == sq and return(false)				# 自分や自分の子には結合不可
		while(pp_sq != @rootsq_sq[pp_sq])
			(pp_sq = @parentsq_sq[pp_sq]) == sq and return(false)
		end

		unjoin_mail(sq) unless(@rootsq_sq[sq] == sq)			# 自分がルート以外の場合

#		@sq_rootsq.delete(x) == sq								# 逆は表示時に消す

		@parentsq_sq[sq] = parent_sq							# 自分の親、自分の親の子を登録
		@childsqs_sq[parent_sq] = '' unless(@childsqs_sq[parent_sq])
		@childsqs_sq[parent_sq] = @childsqs_sq[parent_sq].split(',').push(sq).join(',')
		root_sq = @rootsq_sq[sq] = @rootsq_sq[parent_sq]		# 自分のルートは、親のルートと同じ
		unless((old_rootsq = @parentsq_sq[root_sq]) == @sq_rootsq.last_sq)
			@sq_rootsq[rootsq = @sq_rootsq.inc_sq] = root_sq	# 自分のルートを最新化
			@parentsq_sq[root_sq] = rootsq
			@sq_rootsq.delete(old_rootsq)
		end

		if(@childsqs_sq[sq])									# 自分の子のルートを自分の親のルートに
			each_sq2(sq, 0, true) {|child_sq2, depth2|			# 再帰的に子孫のルートを再設定
				@rootsq_sq[child_sq2] = root_sq
			}
		end

		@dirty += 1
	end

	def unjoin_mail(sq)
		unless(@rootsq_sq[sq] == sq)							# 自分がルート以外の場合
			parent_sq = @parentsq_sq[sq]						# 自分の親の登録から抹消
			@childsqs_sq[parent_sq] = (@childsqs_sq[parent_sq].split(',') - [sq]).join(',')

			@sq_rootsq[rootsq = @sq_rootsq.inc_sq] = @rootsq_sq[sq] = sq
			@parentsq_sq[sq] = rootsq							# ルートの親はrootsqを指す

			if(@childsqs_sq[sq])								# 自分の子のルートを自分に
				each_sq2(sq, 0, true) {|child_sq2, depth2|		# 再帰的に子孫のルートを再設定
					@rootsq_sq[child_sq2] = sq
				}
			end

#### subject_id の付け直しは？
#### 自分が持っていたら、自分が持ち続ける？
#### 人の持っているのを自分のにする？
			@dirty += 1
		end
	end

	def rejoin_mail(sq)
		unjoin_mail(sq) unless(@rootsq_sq[sq] == sq)			# 自分がルート以外の場合

		mail = get_mail(sq); parent_sqi = 0; it = nil			# 直近の親を捜す
		mail.each_in_reply_to {|id|
			parent_sqi = it.to_i if(it = @sq_messageid[id] and it.to_i > parent_sqi)
		}
		mail.each_reference {|id|
			parent_sqi = it.to_i if(it = @sq_messageid[id] and it.to_i > parent_sqi)
		} if(parent_sqi == 0)

		if(parent_sqi == 0)										# 類似の件名から親を捜す
			subject_id = methods.include?(:hash_subject) ? hash_subject(mail.subject) : nil
			subject_id and it = subject_id[0] and it = @sq_subjectid[it] and @rootsq_sq[it] and parent_sqi = it.to_i
		end

		join_mail(sq, parent_sqi.to_s) unless(parent_sqi == 0)	# 親が存在

		@dirty += 1
	end

	#------------------------------------------- MaveFolder ----
	#
	#	フォルダ内にメールを追加する
	#
	def add_mail(mail, flags = nil)
		filename = create_mailfile {|fh|
			mail.rewind
			mail.each {|line|
				fh.write(line)									# ファイルコピー
			}
		}
		@filename_sq[sq = @filename_sq.last_sq] = filename
		@messageid_sq[sq] = mail.message_id

		# 直近の親を捜す
		parent_sqi = 0; it = nil
		mail.each_in_reply_to {|id|
			parent_sqi = it.to_i if(it = @sq_messageid[id] and it.to_i > parent_sqi)
		}
		mail.each_reference {|id|
			parent_sqi = it.to_i if(it = @sq_messageid[id] and it.to_i > parent_sqi)
		} if(parent_sqi == 0)

		@sq_messageid[mail.message_id] = sq
		@abstract_sq[sq] = abstract_of_mail_for_search_cache(sq, mail)	# メール概要登録

		# 類似の件名から親を捜す
		subject_id = methods.include?(:hash_subject) ? hash_subject(mail.subject) : nil
		parent_sqi == 0 and subject_id and it = subject_id[0] and it = @sq_subjectid[it] and @rootsq_sq[it] and parent_sqi = it.to_i

		# 親子関係を登録する
		if(parent_sqi == 0)										# 親が不在->自分がルート
			@sq_rootsq[rootsq = @sq_rootsq.inc_sq] = @rootsq_sq[sq] = sq
			@parentsq_sq[sq] = rootsq							# ルートの親はrootsqを指す
		else
			parent_sq = @parentsq_sq[sq] = parent_sqi.to_s		# 自分の親、自分の親の子を登録
			@childsqs_sq[parent_sq] = '' unless(@childsqs_sq[parent_sq])
			@childsqs_sq[parent_sq] = @childsqs_sq[parent_sq].split(',').push(sq).join(',')
			root_sq = @rootsq_sq[sq] = @rootsq_sq[parent_sq]	# 自分のルートは、親のルートと同じ
			unless((old_rootsq = @parentsq_sq[root_sq]) == @sq_rootsq.last_sq)
				@sq_rootsq[rootsq = @sq_rootsq.inc_sq] = root_sq	# 自分のルートを最新化
				@parentsq_sq[root_sq] = rootsq
				@sq_rootsq.delete(old_rootsq)
			end
			unfold_parents(sq)									# 直系の先祖の折りたたみ状態を解除
		end

		subject_id and it = subject_id[0] and @sq_subjectid[it] = sq
		@flags_sq.set_flags(sq, flags) if(flags)
		red?(sq) and @flags_sq.inc_n('#r_mail#')				# 既読メール総数カウントアップ

		@flags_sq.inc_n											# メール総数カウントアップ

		@dirty += 1
		sq
	end

	def unfold_parents(sq)										# 直系の先祖の折りたたみ状態を解除
		unless(sq == @rootsq_sq[sq])							# 自分がルートなら処理不要
			parent_sq = @parentsq_sq[sq]
			overlap = {}; begin
				break if(overlap[parent_sq])					# ループによる暴走の防止
				unfold(overlap[parent_sq] = parent_sq)
			end until(parent_sq == @rootsq_sq[parent_sq] or (parent_sq = @parentsq_sq[parent_sq] and false))
		end
	end

	#------------------------------------------- MaveFolder ----
	#
	#	フォルダ内のメールを削除
	#
	def delete_mail(sq)
		if(@rootsq_sq[sq] == sq)								# 自分がルートの場合
#	 		@sq_rootsq.delete(x) == sq							# 逆は表示時に消す

			# 親の時は件名 ID レコードがあればそれを削除する
			mail = get_mail(sq)									# 件名 ID の削除
#### 同じ件名 ID を持つ、一番若い子に渡すべき
			subject_id = methods.include?(:hash_subject) ? hash_subject(mail.subject) : nil
			subject_id and it = subject_id[0] and it = @sq_subjectid[it] and it == sq and @sq_subjectid.delete(subject_id[0])

			@sq_messageid.delete(@messageid_sq.delete(sq))
			@rootsq_sq.delete(sq)
			@parentsq_sq.delete(sq)

			if(@childsqs_sq[sq])								# 自分の子をルートに
				@childsqs_sq[sq].split(',').each {|child_sq|
					each_sq2(child_sq, 0, true) {|child_sq2, depth2|	# 再帰的に子孫のルートを再設定
						@rootsq_sq[child_sq2] = child_sq
					}
					@sq_rootsq[@sq_rootsq.inc_sq] = child_sq	# 子は全員、新登場のルート扱いとする
				}
				@childsqs_sq.delete(sq)
			end
		else
			parent_sq = @parentsq_sq[sq]						# 自分の親の登録から抹消

			mail = get_mail(sq)									# 件名 ID の親への付け替え
#### 親が同じ件名 ID だったら渡す
			subject_id = methods.include?(:hash_subject) ? hash_subject(mail.subject) : nil
			subject_id and it = subject_id[0] and it = @sq_subjectid[it] and it == sq and @sq_subjectid[subject_id[0]] = parent_sq

			@childsqs_sq[parent_sq] = (@childsqs_sq[parent_sq].split(',') - [sq]).join(',')

			@sq_messageid.delete(@messageid_sq.delete(sq))
			@rootsq_sq.delete(sq)
			@parentsq_sq.delete(sq)

			if(@childsqs_sq[sq])								# 自分の子を自分の親につなげる
				@childsqs_sq[sq].split(',').each {|child_sq|
					@parentsq_sq[child_sq] = parent_sq
				}
				@childsqs_sq[parent_sq] = @childsqs_sq[parent_sq].split(',').concat(@childsqs_sq[sq].split(',')).sort.join(',')
				@childsqs_sq.delete(sq)
			end
		end

		flags = @flags_sq.get_flags(sq)
		red?(sq) and @flags_sq.dec_n('#r_mail#')				# 既読メール総数カウントダウン
		@flags_sq.dec_n											# メール総数カウントダウン

		@flags_sq.delete(sq)
		@abstract_sq.delete(sq)									# メール概要を消す
		delete(@filename_sq.delete(sq))							# ファイル本体を消す

		@dirty += 1
		flags
	end

	#------------------------------------------- MaveFolder ----
	#
	#	フォルダ内の old_mail を mail で上書きする
	#
	def overwrite_mail(mail, old_mail)	
		filename = overwrite_mailfile(@filename_sq[old_mail.sq]) {|fh|
			mail.rewind
			mail.each {|line|
				fh.write(line)									# ファイルコピー
			}
		}
		old_mail.rewind
		old_mail.parse_header
		old_mail.parse_body
#		@messageid_sq[sq] = mail.message_id						#### メッセージ ID 等、変化するかも
#		@sq_messageid[mail.message_id] = sq
		@dirty += 1
	end

	#------------------------------------------- MaveFolder ----
	#
	#	フォルダ内のメールを返す
	#
	def next_sq(targetsq)										# 次を返す
		each_sq(targetsq) {|sq, depth|
			break sq unless(sq == targetsq)
		}
	end

	def each_sq(startsq = nil, into_folded = false)				# 次を順に渡す
		unless(startsq)
			rootsqi = @sq_rootsq.last_sq.to_i
			started = true
		else
			rootsqi = @parentsq_sq[@rootsq_sq[startsq]].to_i
			started = false
		end
		while(rootsqi > 0)
			if(sq = @sq_rootsq[rootsqi.to_s] and (it = @rootsq_sq[sq]) and it == sq)
				each_sq2(sq, 0, into_folded) {|sq2, depth2|
					started = true if(!started and sq2 == startsq)
					yield(sq2, depth2) if(started)
				}
			else
				@sq_rootsq.delete(rootsqi.to_s)					# 削除/ルートでなくなった番号は消す
			end
			rootsqi -= 1
		end
		nil
	end

	def each_sq2(sq, depth, into_folded = false)				# 再帰的に子を順に渡す
		yield(sq, depth)
		@childsqs_sq[sq].split(',').each {|childsq|
			each_sq2(childsq, depth + 1, into_folded) {|sq2, depth2|
				yield(sq2, depth2)
			}
		} if(@childsqs_sq[sq] and (into_folded or !fold?(sq)))
	end

	def reverse_each_sq(startsq = nil)							# 前を順に渡す
		unless(startsq)
			rootsqi = 0
			started = true
		else
			rootsqi = @parentsq_sq[@rootsq_sq[startsq]].to_i
			started = false
		end
		max_rootsqi = @sq_rootsq.last_sq.to_i; buf = []; while(rootsqi <= max_rootsqi)
			if(sq = @sq_rootsq[rootsqi.to_s] and (it = @rootsq_sq[sq]) and it == sq)
				buf.clear; each_sq2(sq, 0) {|sq2, depth2|
					buf << [sq2, depth2]
				}
				buf.reverse.each {|sq2, depth2|
					started = true if(!started and sq2 == startsq)
					yield(sq2, depth2) if(started)
				}
			else
				@sq_rootsq.delete(rootsqi.to_s)					# 削除/ルートでなくなった番号は消す
			end
			rootsqi += 1
		end
	end

	def previous_sq(targetsq)									# 前を返す
		reverse_each_sq(targetsq) {|sq, depth|
			break sq unless(sq == targetsq)
		}
	end

	#------------------------------------------- MaveFolder ----
	#
	#	各種フラグ処理
	#
	def red(sq)
		red?(sq) or  (@flags_sq.set_flag(sq, :RED, ?R) and @flags_sq.inc_n('#r_mail#'))
		@dirty += 1
	end
	def red?(sq)
		@flags_sq.get_flag(sq, :RED) == ?R
	end
	def unred(sq)
		red?(sq) and (@flags_sq.set_flag(sq, :RED, ?_) and @flags_sq.dec_n('#r_mail#'))
		@dirty += 1
	end

	def flag(sq)
		@flags_sq.set_flag(sq, :FLAG, ?F)
		@dirty += 1
	end
	def flag?(sq)
		@flags_sq.get_flag(sq, :FLAG) == ?F
	end
	def unflag(sq)
		@flags_sq.set_flag(sq, :FLAG, ?_)
		@dirty += 1
	end

	def notice(sq)
		@flags_sq.set_flag(sq, :NOTICE, ?N)
		@dirty += 1
	end
	def notice?(sq)
		@flags_sq.get_flag(sq, :NOTICE) == ?N
	end
	def unnotice(sq)
		@flags_sq.set_flag(sq, :NOTICE, ?_)
		@dirty += 1
	end

	def fold(sq)
		if(@childsqs_sq[sq] and @childsqs_sq[sq].split(',').size != 0)
			@flags_sq.set_flag(sq, :FOLD, ?O)
			@dirty += 1
		end
	end
	def fold?(sq)
		@flags_sq.get_flag(sq, :FOLD) == ?O
	end
	def unfold(sq)
		@flags_sq.set_flag(sq, :FOLD, ?_)
		@dirty += 1
	end

	def toyou(sq)
		@flags_sq.set_flag(sq, :TOYOU, ?T)
		@dirty += 1
	end
	def ccyou(sq)
		@flags_sq.set_flag(sq, :TOYOU, ?C)
		@dirty += 1
	end
	def toyou?(sq)
		'-CT'.index(@flags_sq.get_flag(sq, :TOYOU)) || 0
	end

	#------------------------------------------- MaveFolder ----
	#
	#	メールをエクスポートする
	#
	def export_mail(mail)
		[	"cp '%s' '%s'/ 2>&1" % [mail.path, @folder_configs[:EXPORT_DIRECTORY]],
			"touch '%s'/'%s' 2>&1" % [@folder_configs[:EXPORT_DIRECTORY], mail.path.gsub(/.*\//, '')],
		].each {|export_command|
			error = nil; IO.popen(export_command) {|stdout|
				error = stdout.read
			}
			$?.exitstatus == 0 or return(error.chomp)
		}
		nil
	end

	#------------------------------------------- MaveFolder ----
	#
	#	メールの添付ファイルを展開する
	#
	def extract_attachments(mail, nth = nil)
		target_part = nth ? mail.get_part(nth) : nil
		mail.get_parts_info.each {|part|
			if(!target_part or target_part == part[:PART])
				result = extract_attachment(mail.unique_name, part[:FILENAME], part[:PART])
				yield(result, part)
			end
		}
	end

	#------------------------------------------- MaveFolder ----
	#
	#	メールに添付ファイルを入れ込む
	#
	def enclose_attachments(source_mail)
		return if(source_mail.x_mave_attachments.size == 0)
		halfname = create_mailfile {|fh|						# 一時ファイルに書き出す
			MavePseudoMail.new({:CONFIGS => @configs, :MODE => :ENCLOSE, :MAIL => source_mail}).pseudo_each {|line|
				fh.write(line + "\n")
			}
		}
		mail = MavePseudoMail.new({:CONFIGS => @configs, :FILE => (xmail = File.new(path + '/' + halfname))})
		overwrite_mail(xmail, source_mail)
		delete(halfname) unless(RUBY_PLATFORM =~ /i.86-mswin32/)	####
		@dirty += 1	####
	end

	#------------------------------------------- MaveFolder ----
	#
	#	任意の内容のメールを内部生成する
	#
	def create_mail
		halfname = create_mailfile {|fh|
			yield(fh)
		}
		mail = MavePseudoMail.new({:CONFIGS => @configs, :FILE => File.new(path + '/' + halfname)})
		sq = add_mail(mail)
		delete(halfname) unless(RUBY_PLATFORM =~ /i.86-mswin32/)	####
		@dirty += 1	####
		sq
	end

	#------------------------------------------- MaveFolder ----
	#
	#	シェルコマンドの実行結果をメール化する
	#
	def create_mail_shell_command(header, heads, stdout)
		@dummy_account = {
			:FROM			=> 'mave internal',
		}
		def @dummy_account.hash_id
			Digest::MD5.hexdigest(self[:FROM])[0, 8]
		end
		create_mail {|fh|
			MavePseudoMail.new({:CONFIGS => @configs, :MODE => :NEW, :ACCOUNT => @dummy_account}).header_each {|line|
				if(line =~ /^Subject: /)
					fh.write("Subject: %s\n" % (header['Subject'] || '*Shell Command Output*'))
				elsif(line =~ /^(.+): / and it = header[$1.capitalize])
					fh.write("#{$1}: #{it}\n")
				else
					fh.write(line + "\n")
				end
			}
			fh.write("\n")
			heads.each {|line|
				fh.write(line.chomp + "\n")
			}
			stdout.each {|line|
				fh.write(line.chomp + "\n")
			}
		}
	end

	def close
		@sq_rootsq.reorganize;		@sq_rootsq.close
		@messageid_sq.reorganize;	@messageid_sq.close
		@sq_messageid.reorganize;	@sq_messageid.close
		@sq_subjectid.reorganize;	@sq_subjectid.close
		@rootsq_sq.reorganize;		@rootsq_sq.close
		@parentsq_sq.reorganize;	@parentsq_sq.close
		@childsqs_sq.reorganize;	@childsqs_sq.close
		@abstract_sq.reorganize;	@abstract_sq.close
		@flags_sq.reorganize;		@flags_sq.close
		super
	end
end

#===============================================================================
#
#	メールフォルダ「群」モデルクラス
#
class MaveFolders < MaveBaseModel

	attr_reader :shortcuts

	def initialize(params)
		super
		@folders		= {}
		@shortcuts		= MaveShortcuts.new

		begin
			Dir.open(@configs[:ROOT_DIRECTORY]) {|dir|
				dir.each {|name|
					next if(name =~ /^[._]/ or !File.directory?(dir.path + '/' + name))
					open_folder(name)
				}
			}
		rescue Errno::ENOENT
			ex = ['Prepare the root directory [%2$s]. reason=[%1$s]', $!, @configs[:ROOT_DIRECTORY]]
		rescue Errno::EAGAIN
			ex = ['Another instance is already running. reason=[%1$s]', $!]
		rescue
			ex = ['Unexpected error occurred. reason=[%1$s]', $!]
		end
		print "#{_(ex.shift).decode_cs(@configs[:TERMINAL_CHARSET], 'UTF-8') % [ex.shift.message.split(/\r?\n/)[0], *ex]}\n" or exit if(ex)
	end

	#------------------------------------------ MaveFolders ----
	#
	#	メールフォルダ「群」を通して、メールフォルダを作成／開く
	#
	def open_folder(name, create = true)
		return(false) unless(@folders[name] or create)
		unless(@folders[name])
			it = @folders[name] = MaveFolder.new({:CONFIGS => @configs, :NAME => name})
			@shortcuts.assign(it.configs[:SHORTCUT_HINT] + it.configs[:LIST_NAME] + it.name, it)
			@dirty += 1
		end
		@folders[name]
	end

	def close_folder(name)
		@shortcuts.release(@folders[name])
		@folders[name].close; @dirty += 1; @folders[name] = nil
	end

	#------------------------------------------ MaveFolders ----
	#
	#	メールフォルダを順に渡す
	#
	def each(priority = :LIST_PRIORITY)
		@folders.keys.sort {|name_a, name_b|
			@folders[name_a].configs[priority] <=> @folders[name_b].configs[priority]
		}.each {|name|
			yield(@folders[name])
		}
	end

	#------------------------------------------ MaveFolders ----
	#
	#	メールフォルダの概要を返す
	#
	def abstract_of_folder(folder)
		'%c %c) %s (%d/%d)' % [
			red?(folder) ? ?. : ?x,
			@shortcuts[folder],
			folder.configs[:LIST_NAME],
			(it = folder.flags_sq.get_n.to_i) - folder.flags_sq.get_n('#r_mail#').to_i,
			it,
		]
	end

	#------------------------------------------ MaveFolders ----
	#
	#	未読メールあり処理
	#
	def red(folder)
		folder.flags_sq.reset_n('#unred#')
		@dirty += 1
	end
	def red?(folder)
		folder.flags_sq.n_is_zero?('#unred#')
	end
	def unred(folder)
		folder.flags_sq.inc_n('#unred#')
		@dirty += 1
	end

	#------------------------------------------ MaveFolders ----
	#
	#	メールフォルダの設定ファイルを上書きする
	#
	def overwrite_folder_configs(folder, new_configs)
		File.open(folder.config_filename, 'w', 0600) {|fw| fw.write(new_configs.read) }
		close_folder(folder.name); open_folder(folder.name)
	end

	def close
		each {|folder| folder.close }
	end
end

#===============================================================================
#
#	メールクラス
#
class MaveMail < MaveBaseModel

	attr_reader :folder
	attr_reader :sq
	attr_accessor :binding

	attr_reader :header
	attr_reader :heads

	@@debug_what_charset = false
	@@address_book = false

	#--------------------------------------------- MaveMail ----
	#
	#	キャラクタセット情報表示、切り替え(デバッグ用)
	#
	def self.toggle_what_charset
		@@debug_what_charset = !@@debug_what_charset
	end

	#--------------------------------------------- MaveMail ----
	#
	#	アドレス帳をリンク
	#
	def self.set_address_book(address_book)
		@@address_book = address_book
	end

	def initialize(params)
		super
		@file			= params[:FILE]
		@boundary		= params[:BOUNDARY]
		@folder			= params[:FOLDER]
		@sq				= params[:SQ]
		@size			= 0; size

		parse_header
		parse_body if(@file.is_a?(File))
	end

	def path
		@file.path
	end

	def pos
		@file.pos
	end

	def rewind
		@file.rewind											#### とりあえず
	end

	def each
		@file.each {|line| yield line }							#### とりあえず
	end

	def md5
		Digest::MD5.file(@file.path).to_s
	end

	#--------------------------------------------- MaveMail ----
	#
	#	メールヘッダを解析
	#
	def parse_header
		@header = {}; @heads = []; last = ''
		@file.each {|line|
			line.force_encoding('ASCII-8BIT')
			@heads << line.chomp!
			if(line =~ /^(\S+?):\s*(.*)/)
				@header[last = $1.capitalize] = $2
			elsif(line =~ /^\s+(=\?.*)/)						# encode 部分が連続した場合の特別扱い
				@header[last] << $1
			elsif(last and line =~ /^\s+(.*)/)
				@header[last] << " #{$1}"
			elsif(line =~ /^\s*$/)
				@heads = []
				break
			else
				debug("Mail fatal format error. [%s]" % line)
				@header = {}
				break
			end
		}
	end

	def parse_body
		@content = {
			'type'				=> {
				'type'				=> 'text/plain',
				'param'				=> {
					'charset'			=> 'us-ascii',
				},
			},
			'transfer-encoding'	=> {
				'type'				=> '7bit',
			},
			'disposition'		=> {
				'type'				=> nil,
				'param'				=> {
				},
			},
		}
		#
		#	Content-type, Content-transfer-encoding
		#		http://tools.ietf.org/html/rfc2045
		#
		#	Content-Disposition
		#		http://tools.ietf.org/html/rfc1806
		#
		['type', 'transfer-encoding', 'disposition'].each {|shalf|
			if(@header[it = 'Content-' + shalf])
				qss = []
				tps = @header[it].gsub(/"([^"]*)"/) { qss << $1; '"' }.strip.split(/\s*;\s*/)	#### \" の扱いに問題
				@content[shalf]['type'] = tps.shift.downcase
				tps.each {|ps|
					param = @content[shalf]['param']
					param[$1.downcase] = $2 if(ps =~ %r|(\S+)\s*=\s*(\S+)|)	#### xxx  =  xxx.yyy zzz を許容？
					param[$1.downcase] = qss.shift if($2 == '"')
				}
			end
		}

#### Mixed
#### Alternative
#### Parallel
#### Digest	-> 中のデフォルト content-type を替える必要あり？
#### Signed -> 知らないタイプは Mixed とみなす必要がある

		it = MaveMailParts[@content['type']['type']] || MaveMailParts['unknown']
		@body = it.new(@file, @content, @boundary)
	end

	#--------------------------------------------- MaveMail ----
	#
	#	メールヘッダの行を順に渡す
	#
	def header_each(nobcc = false)
		@file.rewind
		@file.each {|line|
			next  if(nobcc and line =~ /^Bcc:/i)
			break if(line =~ /^\s*$/)
			yield(line.chomp)
		}
	end

	#--------------------------------------------- MaveMail ----
	#
	#	メールボディの行を順に渡す
	#
	def raw_body_each											# header_each の直後専用
		@file.each {|line|
			yield(line.chomp)
		}
	end

	def body_each(start = 0)
		nth = start - 1; while(it = self[nth += 1])
			yield(it)
		end
	end

	def body_reverse_each(start = 0)
		nth = start + 1; while(it = self[nth -= 1])
			yield(it)
		end
	end

	#--------------------------------------------- MaveMail ----
	#
	#	メールの特定の行を返す
	#
	def [](nth)
		line = @body[nth]
		if(line and line.is_a?(String))
			(@@debug_what_charset ? @content['type']['param']['charset'] + ': ' : '') + \
			(@@debug_what_charset ? @content['type']['type'] + ': ' : '') + \
			(@@debug_what_charset ? @content['transfer-encoding']['type'].upcase + ': ' : '') + \
			line.decode_cs('UTF-8', @content['type']['param']['charset'])
		else
			line
		end
	end

	#--------------------------------------------- MaveMail ----
	#
	#	content-type 情報を併せて返すように再定義
	#
	def self.line_with_type
		def [](nth)
			line = @body[nth]
			if(line and line.is_a?(String))
				[@content['type']['type'], line.decode_cs('UTF-8', @content['type']['param']['charset'])]
			elsif(line and line.is_a?(Array))
				[@content['type']['type'], line]
			else
				line
			end
		end
	end

	#--------------------------------------------- MaveMail ----
	#
	#	メールの件名、送信者、宛先、同報、送信時刻などを返す
	#
	def subject
		@header['Subject'] || '--no subject--'
	end
	def from
		@header['From'] || '--no from--'
	end
	def to
		@header['To'] || nil
	end
	def cc
		@header['Cc'] || nil
	end
	def bcc
		@header['Bcc'] || nil
	end
	def date
		Time.rfc2822(@header['Date']).getlocal rescue nil
	end

	def pseudo_from(mode = 'DISP:')
		(it = @header['From']) ? @@address_book.decode(it, mode) : '--from?--'
	end
	def pseudo_to(  mode = 'DISP:')
		(it = @header['To'  ]) ? @@address_book.decode(it, mode) : '--to?--'
	end
	def pseudo_cc(  mode = 'DISP:')
		(it = @header['Cc'  ]) ? @@address_book.decode(it, mode) : nil
	end
	def pseudo_bcc( mode = 'DISP:')
		(it = @header['Bcc' ]) ? @@address_book.decode(it, mode) : nil
	end

	#--------------------------------------------- MaveMail ----
	#
	#	Message-ID を返す
	#
	def message_id
		@message_id || @message_id = @header['Message-id'] =~ /<[^>]+?>/ ? $& : '<incorrect@message-id>'
	end

	#--------------------------------------------- MaveMail ----
	#
	#	Unique name(ファイル名として使える Message-ID)を返す
	#
	def unique_name
		message_id.gsub(/[^0-9A-Z]/i, '_')
	end

	#--------------------------------------------- MaveMail ----
	#
	#	In-Reply-To, References を返す
	#
	def in_reply_to
		@header['In-reply-to'] || nil
	end
	def references
		@header['References' ] || nil
	end
	def each_in_reply_to
		(it = @header['In-reply-to']) and it.scan(/<[^>]+?>/) {|id| yield id }
	end
	def each_reference
		(it = @header['References']) and it.scan(/<[^>]+?>/) {|id| yield id }
	end

	#--------------------------------------------- MaveMail ----
	#
	#	関連パス(添付ファイルの展開パス)を返す
	#
	def related_path
		folder.related_path(unique_name)
	end

	#--------------------------------------------- MaveMail ----
	#
	#	関連ディレクトリ、添付ファイル展開関連のヘッダ情報を返す
	#
	def x_mave_extract_targets
		(it = @header['X-mave-extract-targets']) ? it.strip.split(/\s*,\s*/) : []
	end
	def each_x_mave_extract_target_info
		x_mave_extract_targets.each {|target|
			if(target =~ /folder=(.+);\s*message-id=(.+);\s*seq=(\d+);\s*filename=(.+)/i)
				yield({	:FOLDER		=> $1.strip,
						:MESSAGE_ID	=> $2.strip,
						:SEQ		=> $3.strip,
						:FILENAME	=> $4.strip })
			else
				yield(target)									# 書式エラー
			end
		}
	end
	def set_x_mave_extract_targets(filenames)
		@header['X-mave-extract-targets'] = filenames.join(",\n\t")
	end

	def x_mave_attachments
		(it = @header['X-mave-attachments']) ? it.strip.split(/\s*,\s*/) : []
	end
	def each_x_mave_attachments_fullname
		x_mave_attachments.each {|attachment|
			yield((attachment =~ %r|^/| ? '' : related_path + '/') + attachment)
		}
	end

	def x_mave_relations
		(it = @header['X-mave-relations']) ? it.strip.split(/\s*,\s*/) : []
	end
	def set_x_mave_relations(relations)
		@header['X-mave-relations'] = (x_mave_relations + relations).join(",\n\t")
	end

	#--------------------------------------------- MaveMail ----
	#
	#	メールのサイズを返す
	#
	def size
		@size = @file.lstat.size rescue @size
	end

	#--------------------------------------------- MaveMail ----
	#
	#	マルチパートかどうかを返す
	#
	def multipart?
		@content['type']['type'].index('multipart')
	end

	#--------------------------------------------- MaveMail ----
	#
	#	指定番号行を含んでいる、MailPart インスタンスを返す
	#
	def get_part(nth)
		@body.get_part(nth)
	end

	#--------------------------------------------- MaveMail ----
	#
	#	メールに含まれる、全 MailPart の情報を返す
	#
	def get_parts_info(all = false)								#### キャッシュする
		parts = []; nth = mth = -1; last = nil
		while(it = get_part(nth += 1))
			next if(last == it)
			mth += 1
			parts << {	:PART		=> it,
						:FOLDER		=> folder.name.value_encode,
						:MESSAGE_ID	=> message_id,
						:SEQ		=> mth,
						:FILENAME	=> it.filename || 'mailpart_%02d' % mth,
			} if(all or it.content['disposition']['type'])
			last = it
		end
		parts
	end

	#--------------------------------------------- MaveMail ----
	#
	#	メール情報を返す
	#
	def identify
		yield([_('  Message-Sq: %s'), sq])
		yield([_('  Message-ID: %s'), message_id])
		yield([_('    FilePath: %s'), path.force_encoding('UTF-8')])
		yield([_('    FileSize: %d'), size])
		unless((filenames = folder.related_files(self.unique_name)).size == 0)
			yield([_('Related Path: %s'), related_path])
			n = 0; filenames.each {|filename|
				yield([_('Related File: %d) %s'), n += 1, filename])
			}
		end
#### subject_id debug
		if(subject_id = folder.methods.include?(:hash_subject) ? folder.hash_subject(subject) : nil and it = subject_id[0])
			yield([_('  Subject-ID: %s %s'), it, (it = folder.sq_subjectid[it] and it == sq) ? 'I have' : ''])
		end
	end
end

#===============================================================================
#
#	ダミーメールもどきクラス
#
class MavePseudoMailFile

	def each
		yield("\n")
	end

	def pos
		0
	end
end

#===============================================================================
#
#	メールもどきクラス
#
class MavePseudoMail < MaveMail

	def initialize(params)
		params[:FILE]	= MavePseudoMailFile.new unless(params[:FILE])
		super
		@account		= params[:ACCOUNT]
		@mail			= params[:MAIL]
		@formtype = {
			:NEW			=> method(:new_message_each),
			:RENEW			=> method(:renew_message_each),
			:REPLY			=> method(:reply_message_each),
			:REPLY_TO_ALL	=> method(:reply_to_all_message_each),
			:FORWARD		=> method(:forward_message_each),
			:RESEND			=> method(:resend_message_each),
			:EDIT			=> method(:edit_message_each),
			:VIEW			=> method(:view_message_each),
			:VIEW_RAW		=> method(:view_raw_message_each),
			:ENCLOSE		=> method(:enclose_attachments_each),
		}
		@each_func		= @formtype[params[:MODE]] || nil
		@through_date	= params[:THROUGH_DATE]
	end

	def parse_header
		super
		@body_pos = pos
	end

	#--------------------------------------- MavePseudoMail ----
	#
	#	メールもどきを正規のメール形式で順に渡す
	#
	def each
		in_body = false; header = false
		super {|line|
			line.chomp!
			unless(in_body)
				if(line =~ /^(\S+?):/)
					header = $1.downcase
					if(header == 'from')
						yield("From: #{@@address_book.encode(from, 'SEND:')}\n")
					elsif(header == 'to')
						yield("To: #{  @@address_book.encode(to,   'SEND:')}\n")
					elsif(header == 'cc')
						yield("Cc: #{  @@address_book.encode(cc,   'SEND:')}\n")
					elsif(header == 'bcc')
						yield("Bcc: #{ @@address_book.encode(bcc,  'SEND:')}\n")
					elsif(header == 'subject')
						subject.encode_mh_multi('Subject') {|mhline| yield(mhline + "\n") }
					elsif(header == 'date' and !@through_date)
						yield("Date: #{Time.now.rfc2822}\n")	# Date は現時刻に変更
					elsif(header == 'x-mave-extract-targets')
						yield("X-Mave-Extract-Targets: #{x_mave_extract_targets.join(",\n\t")}\n")
					elsif(header == 'x-mave-relations')
						yield("X-Mave-Relations: #{x_mave_relations.join(",\n\t")}\n")
					else
						yield(line + "\n"); header = false		# ヘッダを仲介
					end
				elsif(line =~ /^\s+.*/)
					yield(line + "\n") unless(header)
				elsif(line =~ /^\s*$/)
					yield("\n"); in_body = true
				else
					raise("Mail format error '#{line.inspect}'")
				end
			else
				yield((line + "\n").encode('ISO-2022-JP', :invalid => :replace, :undef => :replace))	#### ボディを仲介(現状は JIS 固定)
			end
		}
	end

	#--------------------------------------- MavePseudoMail ----
	#
	#	各種メールもどきを順に渡す
	#
	def pseudo_each
		@each_func.call {|line|
			yield(line)
		}
	end

	def header_each
		yield("From: #{@@address_book.decode(@account[:FROM],				'XX:')}")
		yield("To: #{  @@address_book.decode(@account[:DEFAULT_TO]  || '',	'ID:')}")
		yield("Cc: #{  @@address_book.decode(@account[:DEFAULT_CC]  || '',	'ID:')}")
		yield("Bcc: #{ @@address_book.decode(@account[:DEFAULT_BCC] || '',	'ID:')}")
		yield("Subject: #{_('no subject')}")
		yield("Date: #{Time.now.rfc2822}")
		yield("X-Mailer: #{@configs[:MAILER]}")
		yield('Message-ID: <%017.6f.%s@mave.%s>' % [Time.now.to_f, @account.hash_id, @configs[:HOSTNAME]])
		yield('In-Reply-To: ')
		yield('References: ')
		yield('MIME-Version: 1.0')
		yield('Content-Type: text/plain; charset=ISO-2022-JP')	#### アカウントの指定による
		yield('Content-Transfer-Encoding: 7bit')
		yield('X-Mave-Extract-Targets: ')						# 展開用の疑似ヘッダ
		yield('X-Mave-Attachments: ')							# 添付用の擬似ヘッダ
		yield('X-Mave-Relations: ')								# 関連用の擬似ヘッダ
	end

	def quote_each
		yield('')
		yield("---- #{_('Original Message')} ----")
		yield("#{_('      From: ')}#{@mail.from.decode_mh}")	if(@mail.from)
		yield("#{_('        To: ')}#{@mail.to.decode_mh}")		if(@mail.to)	#### 長すぎ注意
		yield("#{_('        Cc: ')}#{@mail.cc.decode_mh}")		if(@mail.cc)
		yield("#{_('   Subject: ')}#{@mail.subject.decode_mh}")	if(@mail.subject)
		yield("#{_('      Sent: ')}#{@mail.date.rfc2822}")		if(@mail.date)	#### 好みの形式
		yield("#{_('Message-ID: ')}#{@mail.message_id}")		if(@mail.message_id)
		yield('')
		@mail.body_each {|line|
			line.chomp!
####		yield((line =~ /^>/ ? ">#{line}" : "> #{line}").gsub(/[\x00-\x1F]/, '^x'))
			yield(line =~ /^>/ ? ">#{line}" : "> #{line}")
		}
	end

	#--------------------------------------- MavePseudoMail ----
	#
	#	新規メールもどき作成
	#
	def new_message_each
		header_each {|line|
			next if(line =~ /^In-Reply-To: /)
			next if(line =~ /^References: /)
			yield(line)
		}
		yield('')
		(it = @account[:GREETING]) and it.chomp.split(/\r?\n/, -1).each {|line|
			yield(line.gsub(/[\x00-\x1F]/, ''))
		}
		(it = @account[:SIGNATURE]) and it.chomp.split(/\r?\n/, -1).each {|line|
			yield(line.gsub(/[\x00-\x1F]/, ''))
		}
	end

	def renew_message_each
	end

	#--------------------------------------- MavePseudoMail ----
	#
	#	返信メールもどき作成
	#
	def reply_message_each
		header_each {|line|
			if(line =~ /^To: /)
				@mail and it = @mail.pseudo_from('ID:') and yield("To: #{it}")
			elsif(line =~ /^Subject: /)
				@mail and it = @mail.subject.decode_mh and yield("Subject: #{('Re: ' + it).group_re}")
			elsif(line =~ /^In-Reply-To: /)
				@mail and it = @mail.message_id and yield("In-Reply-To: #{it}")
			elsif(line =~ /^References: /)
				if(@mail)
					refs = []
					@mail.each_reference   {|id| refs |= [id] }
					@mail.each_in_reply_to {|id| refs |= [id] }
					max_refs = 4; refs.slice!(max_refs >> 1, refs.size - max_refs) if(refs.size > max_refs)
					it = @mail.message_id and refs |= [it]
					yield("References: #{refs.join(' ')}") if(refs.size > 0)
				end
			elsif(line =~ /^X-Mave-Extract-Targets: /)			# 添付ファイルリストをつける
				parts_list = []; @mail.get_parts_info.each {|part|
					parts_list << 'folder=%s; message-id=%s; seq=%d; filename=%s' % \
						[part[:FOLDER], part[:MESSAGE_ID], part[:SEQ], part[:FILENAME]]
				} if(@mail)
				yield("X-Mave-Extract-Targets: #{parts_list.join(",\n\t")}")
			else
				yield(line)
			end
		}
		yield('')
		(it = @account[:GREETING]) and it.chomp.split(/\r?\n/, -1).each {|line|
			yield(line.gsub(/[\x00-\x1F]/, ''))
		}
		(it = @account[:SIGNATURE]) and it.chomp.split(/\r?\n/, -1).each {|line|
			yield(line.gsub(/[\x00-\x1F]/, ''))
		}
		quote_each {|line|
			yield(line)
		} if(@mail)
	end

	def reply_to_all_message_each
		header_each {|line|
			if(line =~ /^To: /)
				@mail and it = @mail.pseudo_from('ID:') + ', ' + @mail.pseudo_to('ID:') and yield("To: #{it.gsub(/,\s*/, ",\n\t")}")
			elsif(line =~ /^Cc: /)
				@mail and yield("Cc: #{@mail.pseudo_cc('ID:') || ''}")
			elsif(line =~ /^Subject: /)
				@mail and it = @mail.subject.decode_mh and yield("Subject: #{('Re: ' + it).group_re}")
			elsif(line =~ /^In-Reply-To: /)
				@mail and it = @mail.message_id and yield("In-Reply-To: #{it}")
			elsif(line =~ /^References: /)
				if(@mail)
					refs = []
					@mail.each_reference   {|id| refs |= [id] }
					@mail.each_in_reply_to {|id| refs |= [id] }
					max_refs = 4; refs.slice!(max_refs >> 1, refs.size - max_refs) if(refs.size > max_refs)
					it = @mail.message_id and refs |= [it]
					yield("References: #{refs.join(' ')}") if(refs.size > 0)
				end
			elsif(line =~ /^X-Mave-Extract-Targets: /)			# 添付ファイルリストをつける
				parts_list = []; @mail.get_parts_info.each {|part|
					parts_list << 'folder=%s; message-id=%s; seq=%d; filename=%s' % \
						[part[:FOLDER], part[:MESSAGE_ID], part[:SEQ], part[:FILENAME]]
				} if(@mail)
				yield("X-Mave-Extract-Targets: #{parts_list.join(",\n\t")}")
			else
				yield(line)
			end
		}
		yield('')
		(it = @account[:GREETING]) and it.chomp.split(/\r?\n/, -1).each {|line|
			yield(line.gsub(/[\x00-\x1F]/, ''))
		}
		(it = @account[:SIGNATURE]) and it.chomp.split(/\r?\n/, -1).each {|line|
			yield(line.gsub(/[\x00-\x1F]/, ''))
		}
		quote_each {|line|
			yield(line)
		} if(@mail)
	end

	def forward_message_each
		header_each {|line|
			if(line =~ /^Subject: /)
				@mail and it = @mail.subject.decode_mh and yield("Subject: #{('Fw: ' + it).group_re(0, 'Fw')}")
			elsif(line =~ /^In-Reply-To: /)
				@mail and it = @mail.message_id and yield("In-Reply-To: #{it}")
			elsif(line =~ /^References: /)
				if(@mail)
					refs = []
					@mail.each_reference   {|id| refs |= [id] }
					@mail.each_in_reply_to {|id| refs |= [id] }
					max_refs = 4; refs.slice!(max_refs >> 1, refs.size - max_refs) if(refs.size > max_refs)
					it = @mail.message_id and refs |= [it]
					yield("References: #{refs.join(' ')}") if(refs.size > 0)
				end
			elsif(line =~ /^X-Mave-Extract-Targets: /)			# 添付ファイルリストをつける
				parts_list = []; @mail.get_parts_info.each {|part|
					parts_list << 'folder=%s; message-id=%s; seq=%d; filename=%s' % \
						[part[:FOLDER], part[:MESSAGE_ID], part[:SEQ], part[:FILENAME]]
				} if(@mail)
				yield("X-Mave-Extract-Targets: #{parts_list.join(",\n\t")}")
			else
				yield(line)
			end
		}
		yield('')
		(it = @account[:GREETING]) and it.chomp.split(/\r?\n/, -1).each {|line|
			yield(line.gsub(/[\x00-\x1F]/, ''))
		}
		(it = @account[:SIGNATURE]) and it.chomp.split(/\r?\n/, -1).each {|line|
			yield(line.gsub(/[\x00-\x1F]/, ''))
		}
		quote_each {|line|
			yield(line)
		} if(@mail)
	end

	#--------------------------------------- MavePseudoMail ----
	#
	#	再送メールもどき作成
	#
	def resend_message_each										#### content-type の扱いに問題あり
		header = false
		@mail.header_each {|line|
			if(line =~ /^(\S+?):/)
				header = $1.downcase
				if(line =~ /^From:/)
					@mail and it = @mail.pseudo_from('XX:') and yield("From: #{it}")
				elsif(line =~ /^To:/)
					@mail and it = @mail.pseudo_to(  'ID:') and yield("To: #{  it.gsub(/,\s*/, ",\n\t")}")
				elsif(line =~ /^Cc:/)
					@mail and it = @mail.pseudo_cc(  'ID:') and yield("Cc: #{  it.gsub(/,\s*/, ",\n\t")}")
				elsif(line =~ /^Bcc:/)
					@mail and it = @mail.pseudo_bcc( 'ID:') and yield("Bcc: #{ it.gsub(/,\s*/, ",\n\t")}")
				elsif(line =~ /^Subject:/)
					@mail and it = @mail.subject.decode_mh  and yield("Subject: #{it}")
				else
					yield(line); header = false
				end
			else
				yield(line) unless(header)
			end
		} if(@mail)
		yield('')
		@mail.body_each {|line|
####		yield(line.chomp.gsub(/[\x00-\x1F]/, '^x'))
			yield(line.chomp)
		} if(@mail)
	end

	#--------------------------------------- MavePseudoMail ----
	#
	#	メールもどきの(再)編集
	#
	def edit_message_each
		header = false
		@mail.header_each {|line|
			if(line =~ /^(\S+?):/)
				header = $1.downcase
				if(line =~ /^From:/)
					@mail and it = @mail.pseudo_from('XX:') and yield("From: #{it}")
				elsif(line =~ /^To:/)
					@mail and it = @mail.pseudo_to(  'ID:') and yield("To: #{  it.gsub(/,\s*/, ",\n\t")}")
				elsif(line =~ /^Cc:/)
					@mail and it = @mail.pseudo_cc(  'ID:') and yield("Cc: #{  it.gsub(/,\s*/, ",\n\t")}")
				elsif(line =~ /^Bcc:/)
					@mail and it = @mail.pseudo_bcc( 'ID:') and yield("Bcc: #{ it.gsub(/,\s*/, ",\n\t")}")
				elsif(line =~ /^Subject:/)
					@mail and it = @mail.subject.decode_mh  and yield("Subject: #{it}")
				else
					yield(line); header = false
				end
			else
				yield(line) unless(header)
			end
		} if(@mail)
		yield('')
		@mail.body_each {|line|
####		yield(line.chomp.gsub(/[\x00-\x1F]/, '^x'))
			yield(line.chomp)
		} if(@mail)
	end

	#--------------------------------------- MavePseudoMail ----
	#
	#	閲覧用メールもどきの作成
	#
	def view_message_each
		header = false
		@mail.header_each {|line|
			if(line =~ /^(\S+?):/)
				header = $1.downcase
				if(line =~ /^From:/)
					@mail and it = @mail.pseudo_from('XX:') and yield("From: #{it}")
				elsif(line =~ /^To:/)
					@mail and it = @mail.pseudo_to(  'XX:') and yield("To: #{  it}")
				elsif(line =~ /^Cc:/)
					@mail and it = @mail.pseudo_cc(  'XX:') and yield("Cc: #{  it}")
				elsif(line =~ /^Bcc:/)
					@mail and it = @mail.pseudo_bcc( 'XX:') and yield("Bcc: #{ it}")
				elsif(line =~ /^Subject:/)
					@mail and it = @mail.subject.decode_mh  and yield("Subject: #{it}")
				else
					yield(line); header = false
				end
			else
				yield(line) unless(header)
			end
		} if(@mail)
		yield('')
		@mail.body_each {|line|
####		yield(line.chomp.gsub(/[\x00-\x1F]/, '^x'))
			yield(line.chomp)
		} if(@mail)
	end

	#--------------------------------------- MavePseudoMail ----
	#
	#	閲覧用メールの作成
	#
	def view_raw_message_each
		@mail.rewind
		@mail.each {|line|
			yield(line.chomp)
		} if(@mail)
	end

	#--------------------------------------- MavePseudoMail ----
	#
	#	ファイル添付メールの作成
	#
	def enclose_attachments_each
		boundary = "FFR-41MR_MAVE_with_#{((rand 65536) + 1).to_s}6th_TFS"
		header = false
		attachments = []
		@mail.header_each {|line|
			if(line =~ /^(\S+?):/)
				header = $1.downcase
				if(header == 'content-type')
					yield("Content-Type: multipart/mixed; boundary=\"#{boundary}\"")
				elsif(header == 'content-transfer-encoding')
					# マルチパートになるので捨てる
				elsif(header == 'x-mave-attachments')
					@mail.each_x_mave_attachments_fullname {|fullname|
						attachments << fullname
					}
				else
					yield(line); header = false
				end
			else
				yield(line) unless(header)
			end
		} if(@mail)

		yield('')
		yield('This is a multi-part message in MIME format.')

		yield("--#{boundary}")									# 本文パート
		yield('Content-Type: text/plain; charset=ISO-2022-JP')
		yield('Content-Transfer-Encoding: 7bit')
		yield('')
		@mail.each {|line|
			yield(line.chomp)
		} if(@mail)

		attachments.each {|fullname|
			yield("--#{boundary}")								# 各添付パート
			mime_type = `#{@configs[:FILE_IDENTIFIER] % fullname}`.chomp
			mime_type = $?.to_i == 0 ? mime_type : 'application/octet-stream; charset=binary' 

			yield("Content-Type: #{mime_type};")
			(it = File.basename(fullname)).rfc2231_encode('name') {|line| yield(line) }

			yield("Content-Disposition: attachment;")
			it.rfc2231_encode('filename') {|line| yield(line) }

			yield('Content-Transfer-Encoding: base64')			#### エンコーディング処理は外部に
			yield('')
			File.open(fullname) {|fh|
				while(bytes = fh.read(57))						# 57 * 4/3 = 76
					yield([bytes].pack('m').gsub(/\n/, ''))
 				end
			}
		}

		yield("--#{boundary}--")
	end
end

#===============================================================================
#
#	アドレス帳クラス
#
class MaveAddressBook < MaveBaseModel

	def initialize(params)
		super
		xdbm_flags		= params[:CONFIGS][:XDBM_FLAGS]
		@address_db		=     XDBM.new(@configs[:ROOT_DIRECTORY] + '/mave.address',	0600, xdbm_flags)
	end

	#-------------------------------------- MaveAddressBook ----
	#
	#	メールアドレスもどきへの変換
	#
	def decode(mail_address, mode = 'DISP:')
		disps = []
		mail_address.split(/,/).each {|mailbox|
			if(mailbox =~ /(.*)<(.+)>/)
				addr = $2.strip
				disp = mode == 'DISP:' ? $1.strip.decode_mh : mailbox.decode_mh
				disp = $1 if(disp =~ /^"(.+)"$/)
				disp = addr if(disp.size == 0)
			else
				addr = disp = mailbox.strip
			end
			it = @address_db[mode + addr] and disp = "--#{it.force_encoding('UTF-8')}--"
			disps << disp.force_encoding('UTF-8')
		}
		disps.join(', ')
	end

	#-------------------------------------- MaveAddressBook ----
	#
	#	メールアドレスへの変換
	#
	def encode(pseudo_address, mode = 'MAIL:')
		mailboxes = []
		pseudo_address.split(/,/).each {|paddr|
			if(paddr.strip =~ /^--(.+)--$/)
				if(it = @address_db['MAIL:' + $1])
					mailbox = (mode == 'SEND:' and it2 = @address_db[mode + it]) ? "#{it2.encode_mh} <#{it}>" : it
				else
					mailbox = "--#{$1}?--"
				end
			else
				if(paddr.strip =~ /^(.+?)\s+<(.+)>$/)
					mailbox = "#{$1.encode_mh} <#{$2}>"
				else
					mailbox = paddr.strip
				end
			end
			mailboxes << mailbox
		}
		mailboxes.join(', ')
	end

	def close
		@address_db.reorganize;		@address_db.close
	end
end

#===============================================================================
#
#	プレビューモデルクラス
#
class MavePreview < MaveBaseModel

	def initialize(params)
		super
	end
end

#===============================================================================
#
#	テキストボックスモデルクラス
#
class MaveTextBox < MaveBaseModel

	attr_reader :prompt
	attr_reader :text

	def initialize(params)
		super
		@text			= params[:TEXT] || ''
	end

	#------------------------------------------ MaveTextBox ----
	#
	#	文字をクリアする
	#
	def clear
		@text = ''
		@dirty += 1
	end

	#------------------------------------------ MaveTextBox ----
	#
	#	文字を削除する
	#
	def delete_backward_char
		@text.chop!												#### 要多バイト文字考慮
		@dirty += 1
	end

	#------------------------------------------ MaveTextBox ----
	#
	#	通常文字を入力する
	#
	def key_entry(key_code)
		@text << key_code.chr
		@dirty += 1
	end

	#------------------------------------------ MaveTextBox ----
	#
	#	文字列をセットする
	#
	def set_text(text)
		@text = text
		@dirty += 1
	end

	#------------------------------------------ MaveTextBox ----
	#
	#	文字列を内部エンコーディングで返す
	#
	def utf8_text
		@text.decode_cs('UTF-8', @configs[:TERMINAL_CHARSET])
	end
end

#===============================================================================
#
#	フォルダ作成モデルクラス
#
class MaveCreateFolder < MaveTextBox

	def initialize(params)
		super
		@folders		= params[:FOLDERS]
	end

	#------------------------------------- MaveCreateFolder ----
	#
	#	新規にフォルダを作成する
	#
	def create_folder
		@folders.open_folder(@text)
	end
end

#===============================================================================
#
#	インクリメンタル検索モデルクラス
#
class MaveIncrementalSearch < MaveTextBox

	def initialize(params)
		super
	end
end

#===============================================================================
#
#	全文検索モデルクラス
#
class MaveFulltextSearch < MaveTextBox

	def initialize(params)
		super
	end
end

#===============================================================================
#
#	外部 Wiki のページの新規作成モデルクラス
#
class MaveWikiCreatePage < MaveTextBox

	def initialize(params)
		super
	end
end

#===============================================================================
#
#	クリップモデルクラス
#
class MaveClip < MaveBaseModel

	def initialize(params)
		super
	end

	#--------------------------------------------- MaveClip ----
	#
	#	メールの切り抜きファイルをローテートする
	#
	def rotate
		suffixes = @configs[:CLIP_ROTATION].reverse				# suffixes = ['.4', '.3', '.2', '.1', '']
		File.unlink(to = @configs[:CLIP_FILENAME] + suffixes.shift) rescue(nil)
		while(suffix = suffixes.shift)
			File.rename(from = @configs[:CLIP_FILENAME] + suffix, to) rescue(nil)
			to = from
		end
	end

	#--------------------------------------------- MaveClip ----
	#
	#	メールの切り抜きファイルを保存する
	#
	def clip_header(mail, nth)
		File.open(@configs[:CLIP_FILENAME], 'a', 0600) {|fh|
			fh.write("#{eval(@configs[:CLIP_HEADER])}")
		}
	end

	def clip_body(mail, nth)
		File.open(@configs[:CLIP_FILENAME], 'a', 0600) {|fh|
			fh.write(@configs[:CLIP_BODY] % mail[nth].chomp.decode_cs(@configs[:EDITOR_CHARSET], 'UTF-8'))
		}
	end

	#--------------------------------------------- MaveClip ----
	#
	#	メールの切り抜きファイルを読み出す
	#
	def open(n_suffixes = 0)
		File.open(@configs[:CLIP_FILENAME] + @configs[:CLIP_ROTATION][n_suffixes]) {|fh|
			yield(fh)
		}
	end
end

#===============================================================================
#
#	ステータスモデルクラス
#
class MaveStatus < MaveBaseModel

	def initialize(params)
		super
		@logs = []
		@max_logs = 1000
	end

	#------------------------------------------- MaveStatus ----
	#
	#	ログを追加
	#
	def log(log)
		@logs << sprintf(*log)
		it = @views[:STATUS] and it.head						# 最終位置へ
		@logs.shift while(@logs.size > @max_logs)
		@dirty += 1
		@views.update											# 表示のリアルタイム更新
	end

	#------------------------------------------- MaveStatus ----
	#
	#	ログの最終行を変更(プログレスバー描画向け)
	#
	def update_lastlog(log)
		@logs.pop
		log(log)
	end

	#------------------------------------------- MaveStatus ----
	#
	#	ログを順に返す
	#
	def recent_each(length, back = 0)
		to = @logs.size - back
		(to - length...to).each {|nth|
			yield(nth < 0 ? nil : @logs[nth])
		}
	end
end

#===============================================================================
#
#	メールパート、ベースクラス
#
class MaveBasePart

	attr_reader :index
	attr_reader :content

	def initialize(file, content, boundary)
		@file = file
		@pos = @file.pos
		@content = content
		@boundary = boundary
	end

	#----------------------------------------- MaveBasePart ----
	#
	#	指定番号行を含んでいる、MailPart インスタンスを返す
	#
	def get_part(nth)
		return(nil) unless(self[nth])
		(it = @index[nth - @offset]).is_a?(MaveMail) ? it.get_part(nth) : self
	end

	#----------------------------------------- MaveBasePart ----
	#
	#	MailPart に付けられている filename を返す
	#
	#		RFC には反するが、通例として B/Q エンコーディングをデコード
	#
	def filename
		filename = (it = @content['disposition']['param']['filename']) ? it.decode_mh : nil
		filename and filename.gsub(%r|(.*)/|, '')				#### 適当にサニタイズ
	end

	#----------------------------------------- MaveBasePart ----
	#
	#	MailPart の内容をデコードして順に返す(添付ファイル抽出用)
	#
	def dump
		encoding = @content['transfer-encoding']['type'].upcase
		@file.pos = @pos
		while(line = @file.gets)
			break if(@boundary and line.index(@boundary))
			yield(line.decode_ec(encoding))
		end
	end

	#----------------------------------------- MaveBasePart ----
	#
	#	RFC 2231 拡張表現をデコードして返す(添付ファイル名抽出用)
	#
	#		http://tools.ietf.org/html/rfc2231
	#
	def decode_rfc2231(params, out_code = 'UTF-8')
		dparams = {}
		ps = {}; params.each {|attr, value|
			if(attr =~ /^([^*]+)\*(\d*)(\*?)$/)
				ps[$1] ||= []
				ps[$1][$2.to_i] = $2.size == 0 ? ['*', value] : [$3, value]
			end
		}
		value = ''; ps.each {|attr, clvals|
			charset = 'us-ascii'
			clvals.each {|c, val|
				if(c == '*')
					charset = $1 and val = $3 if(val =~ /(.*)'(.*)'(.+)/)
					val = val.ext_decode.decode_cs(out_code, charset)
				end
				value << val
			}
			dparams[attr] = value
		}
		dparams
	end
end

#===============================================================================
#
#	メールパート、マルチパートクラス
#
class MaveMultipartMixedPart < MaveBasePart

	def initialize(file, content, boundary)
		super
		@mboundary = @content['type']['param']['boundary']
	end

	def [](nth)
		@index = [@pos] and @offset = nth unless(@index)
		wth = oth = nth - @offset
		(it = @index.size - 1) < oth and oth = it
		begin
			if(@index[oth].is_a?(Integer))						# キャッシュはファイルポインタ？
				@file.pos = @index[oth]
				line = @file.gets
				unless(line and line.index("--#{@mboundary}"))
					@index[oth + 1] = @file.pos unless(@index[oth + 1])
				else
					unless(line.index("--#{@mboundary}--"))
						@index[oth] = MaveMail.new({:CONFIGS => @configs, :FILE => @file, :BOUNDARY => @mboundary})
						line = @index[oth][@offset + oth]
						@index[oth + 1] = @index[oth]
					else
						@index[oth] = @file.pos
						line = self[@offset + oth]
					end
				end
			elsif(@index[oth].is_a?(MaveMail))					# キャッシュは MaveMail インスタンス？
				line = @index[oth][@offset + oth]
				unless(line.is_a?(Integer))
					@index[oth + 1] = @index[oth] unless(@index[oth + 1])
				else
					@index[oth] = line
					line = self[@offset + oth]
				end
			end
			oth += 1
		end until(@index[wth])
		line
	end
end

#===============================================================================
#
#	メールパート、オルタナティブクラス
#
class MaveMultipartAlternativePart < MaveMultipartMixedPart
end

#===============================================================================
#
#	メールパート、プレーンテキストクラス
#
class MaveTextPlainPart < MaveBasePart

	def [](nth)
		return(nil) if(nth < 0)
		encoding = @content['transfer-encoding']['type'].upcase
		if(encoding == 'BASE64' or encoding == 'QUOTED-PRINTABLE')	####
			unless(@index)
				@offset = nth
				lline = ''
				while(line = @file.gets)							# コンテンツ部分を丸ごと 1 行に結合
					break if(@boundary and line.index(@boundary))
					lline << line									#### チカラ技すぎる
					bpos = @file.pos
				end
				@index = lline.decode_ec(encoding).split(/\r?\n/)
				@index.size == 0 and @index << '--no contents--'
				@index << bpos										# boundary の直前位置を保持
			end
			wth = nth - @offset
			if(@index[wth])
				if(@index[wth].is_a?(String))
					line = @index[wth]
				elsif(@index[wth].is_a?(Integer))					# キャッシュはファイルポインタ？
					line = @boundary ? @index[wth] : nil
				end
			else
				line = nil
			end
			line
		else
			@index = [@pos] and @offset = nth unless(@index)
			wth = oth = nth - @offset
			(it = @index.size - 1) < oth and oth = it
			begin
				@file.pos = @index[oth]
				line = @file.gets
				@index[oth += 1] = @file.pos
			end until(@index[wth])
			(line and @boundary and line.index(@boundary)) ? @index[wth] : line
		end
	end
end

#===============================================================================
#
#	メールパート、HTML テキストクラス
#
class MaveTextHtmlPart < MaveTextPlainPart
end

#===============================================================================
#
#	メールパート、カレンダーテキストクラス
#
#		http://tools.ietf.org/html/rfc2445
#
class MaveTextCalendarPart < MaveTextPlainPart
	def [](nth)
		unless(@ical)
			@ical = []; @ical_offset = nth
			@ical << "==\n"
			@ical << "== Content-type [#{@content['type']['type']}] ==\n"
			@ical << "==\n"
			@vcal = []; (nth..9999).each {|nth1|
				line = super(nth1) or break
				if(line.is_a?(Integer))
					@vcal << line
				elsif(line =~ /^\s+(.*)/)
					@vcal.last << $1
				else
					@vcal << line
				end
			}
			vpath = [@vtree = {}]
			@vcal.each {|l|
				if(l =~ /^BEGIN:(.+)/)
					vpath.last[$1] ||= []
					vpath.last[$1] << (it = {})
					vpath << it
				elsif(l =~ /^END:(.+)/)
					vpath.pop
				elsif(l =~ /^(.+?):(.+)/)
					name = $1; value = $2; params = nil
					if(name =~ /^(.+?);(.+)/)
						name = $1; ps = $2; params = {}
						ps.split(';').each {|p|
							p =~ /^(.+?)=(.+)/ ? params[$1] = $2 : params[p] = true
						}
					end
					vpath.last['-'] ||= {}
					vpath.last['-'][name] ||= []
					vpath.last['-'][name] << [value, params]
				else
				end
			}
			(vcalendars = @vtree['VCALENDAR']) and vcalendars.each {|vcalendar|
				(vevents = vcalendar['VEVENT']) and vevents.each {|vevent|
					['SUMMARY', 'LOCATION', 'DTSTART', 'DTEND', 'ORGANIZER', 'ATTENDEE', 'RRULE'].each {|name|
						if(values = vevent['-'][name])
							values.each {|value|
								show = (it = value[0]) ? it : value.inspect
								(name == 'ORGANIZER' or name == 'ATTENDEE') and it = value[1] and it = it['CN'] and show = it
								@ical << (_('%10s: %%s' % name) % show)
							}
						end
					}
					@ical << '=='
				}
				@ical << '=='
			}
			@ical << @vcal.last
		end
		@ical[nth - @ical_offset]
	end
end

#===============================================================================
#
#	メールパート、不明コンテンツクラス
#
class MaveUnknownPart < MaveBasePart

	def [](nth)
		unless(@index)
			@index = []; @offset = nth
			@index << "==\n"
			@index << "== Unknown Content-type [#{@content['type']['type']}] ==\n"
			dtype = @content['disposition']['type'] || 'unknown'
			dparams = decode_rfc2231(@content['disposition']['param'])
			(it = dparams['filename']) and @content['disposition']['param']['filename'] = it
			dfilename = (it = @content['disposition']['param']['filename']) ? it.decode_mh : 'unknown'
			@index << "== Content-Desposition [#{dtype}/#{dfilename}] ==\n"
			@index << "==\n"
			while(line = @file.gets)							# 不明コンテンツ部分を読み飛ばす
				break if(@boundary and line.index(@boundary))
				bpos = @file.pos
			end
			@index << bpos										# boundary の直前に位置
		end
		wth = nth - @offset
		if(@index[wth])
			if(@index[wth].is_a?(String))
				line = @index[wth]
			elsif(@index[wth].is_a?(Integer))					# キャッシュはファイルポインタ？
				line = @boundary ? @index[wth] : nil
			end
		else
			line = nil
		end
		line
	end
end

#===============================================================================
#
#	メールパートの登録
#
MaveMailParts = {
	'multipart/mixed'		=> MaveMultipartMixedPart,
	'multipart/alternative'	=> MaveMultipartAlternativePart,
	'multipart/signed'		=> MaveMultipartMixedPart,
	'text/plain'			=> MaveTextPlainPart,
	'text/html'				=> MaveTextHtmlPart,
	'text/calendar'			=> MaveTextCalendarPart,
	'unknown'				=> MaveUnknownPart,
}

__END__

