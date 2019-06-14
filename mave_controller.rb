class MaveController

	attr_reader :pipe

	  PIPE_RD = 0;   PIPE_WR = 1
	SELECT_RD = 0; SELECT_WR = 1; SELECT_EX = 2

	def initialize(params)
		@configs = params[:CONFIGS]

		# 各モデル生成
		@models = {}
		@models[:STATUS]		= MaveStatus.new({:CONFIGS => @configs}); $status = @models[:STATUS] # デバッグ用
		@models[:PREVIEW]		= MavePreview.new({:CONFIGS => @configs})
		@models[:FOLDERS]		= MaveFolders.new({:CONFIGS => @configs})
		@models[:ACCOUNTS]		= MaveAccounts.new({:CONFIGS => @configs})
		@models[:CREATE_FOLDER]	= MaveCreateFolder.new({		# ダイアログのモデル
									:CONFIGS	=> @configs,
									:FOLDERS	=> @models[:FOLDERS],
								})
		@models[:INC_SEARCH]	= MaveIncrementalSearch.new({:CONFIGS => @configs})
		@models[:FTEXT_SEARCH]	= MaveFulltextSearch.new({:CONFIGS => @configs})
		@models[:WIKI_CREATE_PAGE]	= MaveWikiCreatePage.new({:CONFIGS => @configs})
		@models[:CLIP]			= MaveClip.new({:CONFIGS => @configs})
		@models[:ADDRESS_BOOK]	= MaveAddressBook.new({:CONFIGS => @configs})
		MaveMail.set_address_book(@models[:ADDRESS_BOOK])		# メールクラスにアドレス帳をリンク

		# 各フォルダ初期化
		@models[:ACCOUNTS].each {|account|
			[:INBOX_FOLDER, :DRAFT_FOLDER, :OUTBOX_FOLDER, :SENT_FOLDER, :TRASH_FOLDER].each {|folder|
				@models[:FOLDERS].open_folder(account[folder])
			}
		}

		@exited_pids = []										# 終了した子プロセスの pid キュー
		@editfile_pid = {}										# pid に紐付く編集ファイル

		# シグナルハンドラ定義
		Signal.trap(:HUP) {|sig|								# 外部からのシグナルによる終了要求
			kill_mave(true)
		} unless(RUBY_PLATFORM =~ /i.86-mswin32/)

		Signal.trap(:INT) {|sig|
			kill_mave(true)
		} unless(RUBY_PLATFORM =~ /i.86-mswin32/)

		Signal.trap(:QUIT) {|sig|
			kill_mave(true)
		} unless(RUBY_PLATFORM =~ /i.86-mswin32/)

		Signal.trap(:TERM) {|sig|
			kill_mave(true)
		} unless(RUBY_PLATFORM =~ /i.86-mswin32/)

		@pipe = IO.pipe
		Signal.trap(:CHLD) {|sig|								# 子プロセスが死んだ(エディタが終了した)ら
			begin
				while(Process.waitpid(-1, Process::WNOHANG | Process::WUNTRACED))
					if($?.exited?)
						@exited_pids << $?.pid
					else
						raise('unknown signal')
					end
				end
			rescue Errno::ECHILD
			end
			@pipe[PIPE_WR].putc(0x1B); @pipe[PIPE_WR].putc(?P)	# :mi_pickup_file にて、編集ファイルを回収
		} unless(RUBY_PLATFORM =~ /i.86-mswin32/)

		# 代表ビュー生成
		@views = MaveViews.new({
			:CONTROLLER	=> self,
			:MODELS		=> @models,
			:CHARSET	=> @configs[:TERMINAL_CHARSET],
		})

		@actions = {											# コントローラ自ら実行できるアクション一覧
			:mk_global_import_mail			=> method(:import_mail),
			:mk_global_fetch_mail_pop		=> method(:fetch_mail_pop),
			:mk_global_send_mail_smtp		=> method(:send_mail_smtp),
			:mk_global_toggle_what_scache	=> method(:toggle_what_scache),
			:mk_global_toggle_what_charset	=> method(:toggle_what_charset),
			:mk_global_kill_mave			=> method(:kill_mave),

			:mk_global_previous_account		=> method(:previous_account),
			:mk_global_next_account			=> method(:next_account),

			:mk_global_new					=> method(:new_something),
			:mk_global_renew				=> method(:renew_something),
			:mk_global_reply				=> method(:reply_something),
			:mk_global_reply_to_all			=> method(:reply_to_all_something),
			:mk_global_mforward				=> method(:forward_something),
			:mk_global_resend				=> method(:resend_something),
			:mk_global_edit					=> method(:edit_something),
			:mk_global_view					=> method(:view_something),
			:mk_global_view_raw				=> method(:view_raw_something),

			:mk_global_call_file_manager	=> method(:call_file_manager),
			:mk_global_call_screen_lock		=> method(:call_screen_lock),

			:mi_pickup_file					=> method(:pickup_file),
			:mk_pickup_file_force			=> method(:pickup_file_force),
		}
	end

	def action(command)
		(it = @actions[command]) ? it.call : nil
	end

	#-----------------------------------------------------------
	#
	#	メイン
	#
	def main
		begin
			loop {
				@views.clean
				@views.update									# 代表ビューに再表示を命令
				command = @views.ready(@views.active.name)		# アクティブビュー(キーマップ)を指定して、キー入力待ち
				@views.active.action(command) or				# アクティブビューにコマンドを処理させる
							@views.action(command) or			# 代表ビューにコマンドを処理させる
										action(command)			# ビューが実装してないコマンドは、コントローラ自ら処理する
			}
		rescue
			@views.close
			raise unless($!.message == 'Full stop.')
			print(_('Mave was full stopped.').decode_cs(@configs[:TERMINAL_CHARSET], 'UTF-8') + "\n")
		end
	end

	#-----------------------------------------------------------
	#
	#	任意の内容のメールを生成する
	#
	def generate_mail(header, heads, lines)
		@dummy_account = {
			:FROM	=> 'mave internal',
		}
		def @dummy_account.hash_id
			Digest::MD5.hexdigest(self[:FROM])[0, 8]
		end
		@pop_directory = MaveDirectory.new({:CONFIGS => @configs, :PATH => @configs[:POP_DIRECTORY]}) unless(@pop_directory)
		account = @models[:ACCOUNTS].regular
		begin
			folder = @models[:FOLDERS].open_folder(header['X-Mave-Store-Folder'], false)
			old_mail = (folder and header['X-Mave-Overwrite-Mail']) ? folder.get_mail_by_message_id(header['Message-id']) : false

			halfname = @pop_directory.generate_mailfile(header, heads, lines, account)
			fullname = @pop_directory.path + '/' + halfname
			mail = MavePseudoMail.new({:CONFIGS => @configs, :FILE => File.new(fullname), :THROUGH_DATE => true})

			if(folder)											# フォルダ指定(+メール上書き)配置
				old_mail ? folder.overwrite_mail(mail, old_mail) : folder.add_mail(mail)
				@models[:FOLDERS].unred(folder)
				@pop_directory.delete(halfname) unless(RUBY_PLATFORM =~ /i.86-mswin32/) ####
			else												# 通常のメール振り分け
				@models[:FOLDERS].each(:BIND_PRIORITY) {|folder|
					if(folder.bind?(mail, account))
						sq = folder.add_mail(mail)
						@models[:FOLDERS].unred(folder)
						@pop_directory.delete(halfname) unless(RUBY_PLATFORM =~ /i.86-mswin32/) ####
						break
					end
				}
			end
		rescue
			@models[:STATUS].log([_('Failed to pop mail. reason=[%s]'), $!.message.split(/\r?\n/)[0]])
		end
		@models[:FOLDERS].dirty									# メール数の再表示
		folder
	end

	#-----------------------------------------------------------
	#
	#	メールのインポート
	#
	def import_mail
		m_mail = 0
		@models[:ACCOUNTS].each {|account|
			next unless(account.import_command)
			@models[:STATUS].log([_("Account '%1$s' executing import command [%2$s]..."), account.name, account.import_command])
			begin
				n_mail = 0; max_n_mail = 0; target = ''
				@models[:STATUS].log([_('Import checking (%d) [%s]...'), max_n_mail, target])
				IO.popen(account.import_command) {|stdout|
					stdout.each {|fullname|
						target = fullname.chomp
						@models[:STATUS].update_lastlog([_('Import checking (%d) [%s]...'), max_n_mail, target]) if(max_n_mail % 100 == 0)
						MaveMail.new({:CONFIGS => @configs, :FILE => File.new(target)})
						max_n_mail += 1
					}
				}
				@models[:STATUS].update_lastlog([_('%d mails are checked for import.'), max_n_mail])

				IO.popen(account.import_command) {|stdout|		# 敢えて 2 パスで実行
					stdout.each {|fullname|
						target = fullname.chomp
						mail = MaveMail.new({:CONFIGS => @configs, :FILE => File.new(target)})

						@models[:FOLDERS].each(:BIND_PRIORITY) {|folder|
							if(folder.bind?(mail, account))
								sq = folder.add_mail(mail)
								(it = mail.cc) and it.index(account.mail_from) and folder.ccyou(sq)
								(it = mail.to) and it.index(account.mail_from) and folder.toyou(sq)
								@models[:FOLDERS].unred(folder)
								break
							end
						}

						m_mail += 1; n_mail += 1
						@models[:STATUS].log([_('Imported (%1$d/%2$d) from [%3$s] [%4$s]'),
							n_mail, max_n_mail, mail.pseudo_from.force_encoding('UTF-8'), mail.subject.decode_mh.force_encoding('UTF-8')])
					}
				}
			rescue
				@models[:STATUS].log([_('Failed to imported mail. file=[%s] reason=[%s]'), target, $!.message.split(/\r?\n/)[0]])
			end
		}
		result_message = (it = m_mail) != 0 ? '%1$s mail%2$s imported.' : 'no mails imported.'
		@models[:STATUS].log([_(result_message), it.to_s, it == 1 ? '' : 's'])
		@models[:FOLDERS].dirty									# メール数の再表示
	end

	#-----------------------------------------------------------
	#
	#	メール受信(POP)
	#
	def fetch_mail_pop
		@pop_directory = MaveDirectory.new({:CONFIGS => @configs, :PATH => @configs[:POP_DIRECTORY]}) unless(@pop_directory)
		m_mail = 0
		@models[:ACCOUNTS].each {|account|
			next unless(account.pop_server)
			@models[:STATUS].log([_("Account '%1$s' connecting POP server '%2$s'..."), account.name, account.pop_server])
			begin
				n_mail = 0; max_n_mail = 9999
				account.pop {|popmail|
					@models[:STATUS].log([popmail]) and next if(popmail.is_a?(String))
					max_n_mail = popmail and next if(popmail.is_a?(Integer))
					halfname = @pop_directory.create_mailfile {|fh|
						popmail.pop {|line|
							fh.write(line)
						}
					}
					fullname = @pop_directory.path + '/' + halfname
					mail = MaveMail.new({:CONFIGS => @configs, :FILE => File.new(fullname)})

					debug('Subject: %s' % mail.subject.decode_mh) if(debug = false)	# 振り分けのデバッグ
					@models[:FOLDERS].each(:BIND_PRIORITY) {|folder|
						debug('  %5s %3d: [%s] %s [%s]' % [folder.bind?(mail, account), folder.configs[:BIND_PRIORITY], mail.binding, folder.name, account[:TRASH_FOLDER]]) if(debug)
						if(folder.bind?(mail, account))
							sq = folder.add_mail(mail)
							(it = mail.cc) and it.index(account.mail_from) and folder.ccyou(sq)
							(it = mail.to) and it.index(account.mail_from) and folder.toyou(sq)
							@models[:FOLDERS].unred(folder)
							@pop_directory.delete(halfname) unless(RUBY_PLATFORM =~ /i.86-mswin32/)	####
							break
						end
					}

					m_mail += 1; n_mail += 1
					@models[:STATUS].log([_('Popped (%1$d/%2$d) from [%3$s] [%4$s]'),
						n_mail, max_n_mail, mail.pseudo_from, mail.subject.decode_mh])
				}
			rescue
				@models[:STATUS].log([_('Failed to pop mail. reason=[%s]'), $!.message.split(/\r?\n/)[0]])
			end
		}
		result_message = (it = m_mail) != 0 ? '%1$s mail%2$s popped.(%3$s)' : 'no mails popped.(%3$s)'
		@models[:STATUS].log([_(result_message), it.to_s, it == 1 ? '' : 's', Time.now.myexectime])
		@models[:FOLDERS].dirty									# メール数の再表示
		it = @configs[:POP_HOOK_COMMAND] and system(it)
	end

	#-----------------------------------------------------------
	#
	#	メール送信(SMTP)
	#
	def send_mail_smtp
		m_mail = 0
		account = @models[:ACCOUNTS].regular
		if(account.smtp_server)
			begin
				n_mail = 0; max_n_mail = 9999
				outbox_folder = @models[:FOLDERS].open_folder(account[:OUTBOX_FOLDER])
				sent_folder   = @models[:FOLDERS].open_folder(account[:SENT_FOLDER])
				has_presend  = outbox_folder.methods.include?(:presend)
				has_postsend = outbox_folder.methods.include?(:postsend)
				send_sqs = []; outbox_folder.each_sq {|sq, level|
					send_sqs << sq
				}
				if((max_n_mail = send_sqs.size) > 0)
					@models[:STATUS].log([_("Account '%1$s' connecting SMTP server '%2$s'..."), account.name, account.smtp_server])
					account.smtp {|smtp|
						@models[:STATUS].log([smtp]) and next if(smtp.is_a?(String))
						send_sqs.each {|sq|
							mail = outbox_folder.get_mail(sq)
							has_presend and outbox_folder.presend(mail)		# 送信前チェック関数を呼ぶ

							rcpt_to = []							#### 暫定
							it = mail.to  and rcpt_to << it
							it = mail.cc  and rcpt_to << it
							it = mail.bcc and rcpt_to << it
							rcpt_to = rcpt_to.join(',').strip.split(/\s*,\s*/)
							rcpt_to.each {|to|
								to.gsub!(/.*\<(.+)\>.*/) { $1 }
							}
							@models[:STATUS].log(['rcpt to=%s', rcpt_to.inspect]) if(debug = false)	# 送信先のデバッグ

							outbox_folder.enclose_attachments(mail)	# 必要なら、メールに添付ファイルを入れ込む
							result = smtp.ready(account.mail_from, rcpt_to) {|fw|
								mail.header_each(nobcc = true) {|line|
									fw.write(line + "\r\n")
								}
								fw.write("\r\n")
								mail.raw_body_each {|line|
									fw.write(line + "\r\n")
								}
							}
							m_mail += 1; n_mail += 1
							result_message = RUBY_VERSION >= '1.8.7' ? result.message : result
							@models[:STATUS].log([_('Sent (%1$d/%2$d) [%3$s] to [%4$s] [%5$s]'),
								n_mail, max_n_mail, result_message.chomp, mail.pseudo_to, mail.subject.decode_mh])

							flags = outbox_folder.delete_mail(sq)
							sent_folder.add_mail(mail, flags)
							outbox_folder.move_related_directory(mail.unique_name, sent_folder)

							has_postsend and outbox_folder.postsend(mail)	# 送信直後チェック関数を呼ぶ
						}
					}
				end
			rescue
				@models[:STATUS].log([_('Failed to send mail. reason=[%s]'), $!.message.split(/\r?\n/)[0]])
			end
		end
		result_message = (it = m_mail) != 0 ? '%1$s mail%2$s sent.(%3$s)' : 'no mails sent.(%3$s)'
		@models[:STATUS].log([_(result_message), it.to_s, it == 1 ? '' : 's', Time.now.myexectime])
		@models[:FOLDERS].dirty									# メール数の再表示
	end

	#-----------------------------------------------------------
	#
	#	既定のメールアカウントを変更
	#
	def previous_account
		account = @models[:ACCOUNTS].previous
		@models[:STATUS].log([_('Change current account to [%s].'), account[:NAME]])
	end

	def next_account
		account = @models[:ACCOUNTS].next
		@models[:STATUS].log([_('Change current account to [%s].'), account[:NAME]])
	end
 
	#-----------------------------------------------------------
	#
	#	各種編集作業
	#
	def new_something
		if(@views.active.is_a?(MaveSummaryView) \
		or @views.active.is_a?(MavePreviewView))				# 新規のメッセージを作成
			@models[:STATUS].log([_('Create new message.')])
			edit_message({:MODE => :NEW, :MAIL => true})
		elsif(@views.active.is_a?(MaveFolderListView))			# 新規にフォルダを作成
			@models[:STATUS].log([_('Create new folder.')])
			@views[:FOLDERLIST].create_folder
		end
	end

	def renew_something											# 宛先を流用して新規にメッセージを作成
		@models[:STATUS].log([_('Function not provided yet.')])
	end

	def reply_something											# 返信メッセージを編集
		if(@views.current.is_a?(MaveMail))
			@models[:STATUS].log([_('Create reply message.')])
			edit_message({:MODE => :REPLY, :MAIL => @views.current})
		end
	end

	def reply_to_all_something									# 全員への返信メッセージを編集
		if(@views.current.is_a?(MaveMail))
			@models[:STATUS].log([_('Create reply to all message.')])
			edit_message({:MODE => :REPLY_TO_ALL, :MAIL => @views.current})
		end
	end

	def forward_something										# 転送メッセージを編集
		if(@views.current.is_a?(MaveMail))
			@models[:STATUS].log([_('Create forward message.')])
			edit_message({:MODE => :FORWARD, :MAIL => @views.current})
		end
	end

	def resend_something										# 再送メッセージを編集
		if(@views.current.is_a?(MaveMail))
			@models[:STATUS].log([_('Resend reply message.')])
			edit_message({:MODE => :RESEND, :MAIL => @views.current})
		end
	end

	def edit_something
		if(@views.current.is_a?(MaveMail))						# 既存のメッセージを編集
			@models[:STATUS].log([_('Edit message.')])
			edit_message({:MODE => :EDIT, :MAIL => @views.current})
		elsif(@views.current.is_a?(MaveFolder))					# 既存のフォルダの設定ファイルを編集
			@models[:STATUS].log([_('Edit folder configs.')])
			edit_folder_configs({:MODE => :EDIT, :FOLDER => @views.current})
		end
	end

	def view_something
		if(@views.current.is_a?(MaveMail))						# メッセージを閲覧
			@models[:STATUS].log([_('View message.')])
			view_message({:MODE => :VIEW, :MAIL => @views.current})
		end
	end

	def view_raw_something
		if(@views.current.is_a?(MaveMail))						# メッセージを閲覧
			@models[:STATUS].log([_('View raw message.')])
			view_message({:MODE => :VIEW_RAW, :MAIL => @views.current})
		end
	end

	#-----------------------------------------------------------
	#
	#	メッセージファイルをエディタで編集させる
	#
	def edit_message(params)
		@pop_directory = MaveDirectory.new({:CONFIGS => @configs, :PATH => @configs[:POP_DIRECTORY]}) unless(@pop_directory)
		@force_kill = false
		begin
			params[:ACCOUNT] = @models[:ACCOUNTS].regular
			params[:HALFNAME] = @pop_directory.create_mailfile {|fh|
				MavePseudoMail.new({:CONFIGS => @configs}.update(params)).pseudo_each {|line|
					fh.write(line + "\n")
				}
			}
			params[:FORMHASH] = @pop_directory.md5(params[:HALFNAME])
			params[:SOURCEHASH] = params[:MAIL].md5 if(params[:MODE] == :EDIT)	# 編集開始時点の、編集元のハッシュ

			unless(@configs[:EDITOR_TYPE] == 'forkexec')		# 一旦 Curse を閉じて、エディタアプリを起動する場合
				@views.close
				system(@configs[:EDITOR] % (@pop_directory.path + '/' + params[:HALFNAME]))
				_pickup_file(params)
				@views.reopen
			else												# 別途ウィンドウで、エディタアプリを起動する場合
				pid = fork {
					exec(@configs[:EDITOR] % (@pop_directory.path + '/' + params[:HALFNAME]))
				}
				@editfile_pid[pid.to_s] = params
			end
		rescue
			@models[:STATUS].log([_('Failed to editing mail. reason=[%s]'), $!.message.split(/\r?\n/)[0]])
		end
	end

	#-----------------------------------------------------------
	#
	#	メッセージファイルをビューアで閲覧させる
	#
	def view_message(params)
		@pop_directory = MaveDirectory.new({:CONFIGS => @configs, :PATH => @configs[:POP_DIRECTORY]}) unless(@pop_directory)
		begin
			params[:ACCOUNT] = @models[:ACCOUNTS].regular
			params[:HALFNAME] = @pop_directory.create_mailfile {|fh|
				MavePseudoMail.new({:CONFIGS => @configs}.update(params)).pseudo_each {|line|
					fh.write(line + "\n")
				}
			}

			unless(@configs[:VIEWER_TYPE] == 'forkexec')		# 一旦 Curse を閉じて、ビューアアプリを起動する場合
				@views.close
				system(@configs[:VIEWER] % (@pop_directory.path + '/' + params[:HALFNAME]))
#				pickup_file_force
				@pop_directory.delete(params[:HALFNAME]) unless(RUBY_PLATFORM =~ /i.86-mswin32/)	####
				@views.reopen
			else												# 別途ウィンドウで、ビューアアプリを起動する場合
				pid = fork {
					exec(@configs[:VIEWER] % (@pop_directory.path + '/' + params[:HALFNAME]))
				}
				@editfile_pid[pid.to_s] = params
			end
		rescue
			@models[:STATUS].log([_('Failed to viewing mail. reason=[%s]'), $!.message.split(/\r?\n/)[0]])
		end
	end

	#-----------------------------------------------------------
	#
	#	フォルダの設定ファイルをエディタで編集させる
	#
	def edit_folder_configs(params)
		@pop_directory = MaveDirectory.new({:CONFIGS => @configs, :PATH => @configs[:POP_DIRECTORY]}) unless(@pop_directory)
		@force_kill = false
		begin
			params[:HALFNAME] = @pop_directory.create_mailfile {|fh|
				open(params[:FOLDER].config_filename) {|fr|
					fh.write(fr.read)
				}
			}
			params[:FORMHASH] = @pop_directory.md5(params[:HALFNAME])
			params[:SOURCEHASH] = params[:FOLDER].md5 if(params[:MODE] == :EDIT)	# 編集開始時点の、編集元のハッシュ

			unless(@configs[:EDITOR_TYPE] == 'forkexec')		# 一旦 Curse を閉じて、エディタアプリを起動する場合
				@views.close
				system(@configs[:EDITOR] % (@pop_directory.path + '/' + params[:HALFNAME]))
				_pickup_file(params)
				@views.reopen
			else												# 別途ウィンドウで、エディタアプリを起動する場合
				pid = fork {
					exec(@configs[:EDITOR] % (@pop_directory.path + '/' + params[:HALFNAME]))
				}
				@editfile_pid[pid.to_s] = params
			end
		rescue
			@models[:STATUS].log([_('Failed to editing folder configs. reason=[%s]'), $!.message.split(/\r?\n/)[0]])
		end
	end

	#-----------------------------------------------------------
	#
	#	エディタで編集済みのファイルを回収する
	#
	def pickup_file
		while(pid = @exited_pids.shift)
			_pickup_file(@editfile_pid[pid.to_s])
			@editfile_pid.delete(pid.to_s)
		end
	end

	def pickup_file_force										# プロセス終了時以外の任意のタイミングで強制回収
		@editfile_pid.each {|pid, instance|
			_pickup_file(@editfile_pid[pid.to_s])
			@editfile_pid.delete(pid.to_s)
		}
	end

	def _pickup_file(editfile)
		return unless(editfile)
		@pop_directory = MaveDirectory.new({:CONFIGS => @configs, :PATH => @configs[:POP_DIRECTORY]}) unless(@pop_directory)
		if(editfile[:MODE] == :VIEW)
			@pop_directory.delete(editfile[:HALFNAME]) unless(RUBY_PLATFORM =~ /i.86-mswin32/)	####
			return
		end
		unless(editfile[:FORMHASH] == @pop_directory.md5(editfile[:HALFNAME]))	# (編集前 == 現在)？
			if(editfile[:MAIL])
				mail = MavePseudoMail.new({:CONFIGS => @configs, :FILE => File.new(@pop_directory.path + '/' + editfile[:HALFNAME])})
				unless(editfile[:MODE] == :EDIT)								# 新規
					folder = @models[:FOLDERS].open_folder(editfile[:ACCOUNT][:DRAFT_FOLDER])
					create_new_relations(mail, folder)							# 新規関連ファイル作成処理
					extract_attachments(mail, folder)							# 添付ファイル展開処理
					folder.add_mail(mail)
					@models[:FOLDERS].unred(folder)
					@models[:STATUS].log([_('The message was stored in the [%s] folder.'), folder.configs[:LIST_NAME]])
				else
					if(editfile[:SOURCEHASH] == editfile[:MAIL].md5)			# (編集前 == 現在)？
						create_new_relations(mail, editfile[:MAIL].folder)		# 新規関連ファイル作成処理
						extract_attachments(mail, editfile[:MAIL].folder)		# 添付ファイル展開処理
						editfile[:MAIL].folder.overwrite_mail(mail, editfile[:MAIL])
						editfile[:MAIL].folder.delete_abstract(editfile[:MAIL].sq)
						@models[:STATUS].log([_('The message was overwrited.')])
					else
						create_new_relations(mail, editfile[:MAIL].folder)		# 新規関連ファイル作成処理
						extract_attachments(mail, editfile[:MAIL].folder)		# 添付ファイル展開処理
						editfile[:MAIL].folder.add_mail(mail)
						@models[:FOLDERS].unred(editfile[:MAIL].folder)
						@models[:STATUS].log([_('The message was stored as another one (edit collision was detected).')])
					end
				end
			elsif(editfile[:FOLDER])
				if(editfile[:SOURCEHASH] == editfile[:FOLDER].md5)				# (編集前 == 現在)？
					folder = @models[:FOLDERS].overwrite_folder_configs(editfile[:FOLDER], File.new(@pop_directory.path + '/' + editfile[:HALFNAME]))
					@views[:SUMMARY].tie(folder)
					@views[:FOLDERLIST].list_items; @views[:FOLDERLIST].target_cursor(folder)
					@models[:STATUS].log([_('Folder configs were overwrited.')])
				else
#					editfile[:FOLDER].folder.add_mail(mail)						#### 別名で保存しておく
					@models[:STATUS].log([_('Folder configs were discarded (edit collision was detected).')])
				end
			else
				@models[:STATUS].log([_('The file was discarded (unexpected type).')])
			end
		else
			@models[:STATUS].log([_('The message was discarded.')])		if(editfile[:MAIL])
			@models[:STATUS].log([_('Folder configs were discarded.')])	if(editfile[:FOLDER])
		end
		@pop_directory.delete(editfile[:HALFNAME]) unless(RUBY_PLATFORM =~ /i.86-mswin32/)	####
		@models[:FOLDERS].dirty									# メール数の再表示
		@views[:PREVIEW].untie
	end

	#-----------------------------------------------------------
	#
	#	新規に関連ファイルを作成する
	#
	def create_new_relations(mail, folder)
		mail.x_mave_relations.each {|relation|
			if(folder.create_new_relation(mail.unique_name, relation))
				@models[:STATUS].log([_('Create related file. file=[%s]'), relation])
#			else
#				@models[:STATUS].log([_('Skipped to create related file. file=[%s] reason=[File exist]'), relation])
			end
		}
	end

	#-----------------------------------------------------------
	#
	#	メールパート(添付)を展開する
	#
	def extract_attachments(mail, folder)
		filenames = []; faileds = []
		mail.each_x_mave_extract_target_info {|relation|
			begin
				relation.is_a?(String) and raise('format')
				rfolder = @models[:FOLDERS].open_folder(relation[:FOLDER], false) or raise('folder')
				rmail = rfolder.get_mail_by_message_id(relation[:MESSAGE_ID]) or raise('message_id')
				part = rmail.get_parts_info(true)[relation[:SEQ].to_i] or raise('seq')
				if(folder.extract_attachment(mail.unique_name, relation[:FILENAME], part[:PART]))
					@models[:STATUS].log([_('Extracted attached file. file=[%s]'), relation[:FILENAME].force_encoding('UTF-8')])
				else
					@models[:STATUS].log([_('Skipped to extract attached file. file=[%s] reason=[File exist]'), relation[:FILENAME].force_encoding('UTF-8')])
				end
				filenames << relation[:FILENAME]
			rescue
				case($!.message)
				when('format');		@models[:STATUS].log([_('X-Mave-Extract-Targets header is not collect. header=[%s]'), relation])
				when('folder');		@models[:STATUS].log([_('Target folder is not found. folder=[%s]'), relation[:FOLDER]])
				when('message_id');	@models[:STATUS].log([_('Target message_id is not found. message_id=[%s]'), relation[:MESSAGE_ID]])
				when('seq');		@models[:STATUS].log([_('Target part is not found. seq=[%s]'), relation[:SEQ]])
				else;				@models[:STATUS].log([_('Failed to extract attachment. file=[%s] reason=[%s]'), relation[:FILENAME].force_encoding('UTF-8'), $!.message.split(/\r?\n/)[0].force_encoding('UTF-8')])
				end
				faileds << relation if(relation.is_a?(String))
				faileds << 'folder=%s; message-id=%s; seq=%d; filename=%s' % \
					[relation[:FOLDER], relation[:MESSAGE_ID], relation[:SEQ], relation[:FILENAME]] if(relation.is_a?(Hash))
			end
		}
		mail.set_x_mave_extract_targets(faileds)
		mail.set_x_mave_relations(filenames)
	end

	#-----------------------------------------------------------
	#  
	#	ファイルマネージャを呼び出す
	#
	def call_file_manager
		target_dir = nil
		if((it = @views.current).is_a?(MaveMail))
			target_dir = it.related_path
		elsif((it = @views.current).is_a?(MaveFolder))
			target_dir = it.path
		end
		if(target_dir)
			begin
				unless(@configs[:FILE_MANAGER_TYPE] == 'forkexec')
					@views.close
					system(@configs[:FILE_MANAGER] % target_dir)
#					pickup_file_force
					@views.reopen
				else
					pid = fork {
						exec(@configs[:FILE_MANAGER] % target_dir)
					}
				end
			rescue
				@models[:STATUS].log([_('Failed to start file manager. reason=[%s]'), $!.message.split(/\r?\n/)[0]])
			end
		end
	end

	#-----------------------------------------------------------
	#  
	#	画面ロックを呼び出す
	#
	def call_screen_lock
		it = @configs[:SCREEN_LOCK_COMMAND] and system(it)
		@models[:STATUS].log([_('Screen Locked.(%s)'), Time.now.myexectime])
	end

	#-----------------------------------------------------------
	#
	#	メールの概要キャッシュ(インクリメンタルサーチ用)表示、切り替え
	#
	def toggle_what_scache
		state = MaveFolder.toggle_what_scache
		@models[:STATUS].log(['what search cache: %s', state.to_s])
		@views[:SUMMARY].list_items
	end

	#-----------------------------------------------------------
	#
	#	キャラクタセット情報の表示、切り替え(デバッグ用)
	#
	def toggle_what_charset
		state = MaveMail.toggle_what_charset
		@models[:STATUS].log(['what charset: %s', state.to_s])
	end

	#-----------------------------------------------------------
	#
	#	終了する
	#
	def kill_mave(force_kill = false)
		unless((it = @editfile_pid.size) < 1 or @force_kill or force_kill)
			@models[:STATUS].log([_('%1$d editor%2$s alive.'), it, it == 1 ? ' is' : 's are'])
			@force_kill = true
		else
			@models[:FOLDERS].close
			@models[:ACCOUNTS].close
			@models[:ADDRESS_BOOK].close
			@pop_directory.close if(@pop_directory)
			it = @configs[:KILL_HOOK_COMMAND] and system(it)
			raise 'Full stop.'
		end
	end
end

__END__

