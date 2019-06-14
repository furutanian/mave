#  coding: utf-8

require 'curses'

#===============================================================================
#
#	Curses 版、代表ビュー
#
class MaveViews < Hash

	attr_reader :controller										#### 必要？
	attr_reader :charset
	attr_reader :key

	def initialize(params)
		@controller	= params[:CONTROLLER]
		@models		= params[:MODELS]
		@charset	= params[:CHARSET]
		String.set_snip_charset(@charset)

		open

		@screen_x_size = lx = Curses.cols  - 0
		@screen_y_size = ly = Curses.lines - 0

		vx1 = lx / 5
		vx2 = lx / 5 * 4
		vx3 = lx / 5 * 2
		vy1 = ly / 5 * 4										# ステータスウィンドウとの境界
		vy2 = ly / 5 * 1
		vy3 = ly / 7 * 6
		vy4 = ly / 5 * 2

		self[name = :STATUS]		=	MaveStatusView.new({
											:NAME		=> name,						# ビューの名前
											:VIEWS		=> self,						# 親ビュー(自分)を渡す
											:GEOMETRY	=> [0, vy1, lx, ly - vy1],		# 初期状態のウィンドウジオメトリ
										})

		self[name = :FOLDERLIST]	=	MaveFolderListView.new({
											:NAME		=> name,
											:VIEWS		=> self,
											:GEOMETRY	=> [0, 0, vx1 + 1, vy1 + 1],
											:STATUS		=> @models[:STATUS],
										})

		self[name = :SUMMARY]		=	MaveSummaryView.new({
											:NAME		=> name,
											:VIEWS		=> self,
											:GEOMETRY	=> [0, 0, vx2 + 1, vy1 + 1],
											:STATUS		=> @models[:STATUS],
										})

		self[name = :PREVIEW]		=	MavePreviewView.new({
											:NAME		=> name,
											:VIEWS		=> self,
											:GEOMETRY	=> [vx2, 0, lx - vx2, vy1 + 1],
											:CLIP		=> @models[:CLIP],
											:STATUS		=> @models[:STATUS],
										})

		self[name = :CREATE_FOLDER]	=	MaveCreateFolderView.new({
											:NAME		=> name,
											:VIEWS		=> self,
											:GEOMETRY	=> [vx3, vy2, lx / 2, 4],
											:STATUS		=> @models[:STATUS],
										})

		self[name = :INC_SEARCH]	=	MaveIncrementalSearchView.new({
											:NAME		=> name,
											:VIEWS		=> self,
											:GEOMETRY	=> [vx3, vy3, lx / 2, 4],
											:STATUS		=> @models[:STATUS],
										})

		self[name = :FTEXT_SEARCH]	=	MaveFulltextSearchQueryView.new({
											:NAME		=> name,
											:VIEWS		=> self,
											:GEOMETRY	=> [vx3, vy4, lx / 2, 4],
											:STATUS		=> @models[:STATUS],
										})

		self[name = :WIKI_CREATE_PAGE]	=	MaveWikiCreatePageView.new({
											:NAME		=> name,
											:VIEWS		=> self,
											:GEOMETRY	=> [vx3, vy2, lx / 2, 4],
											:STATUS		=> @models[:STATUS],
										})

		self[:STATUS].tie(@models[:STATUS])						# ビューに表示対象モデルを割り当てる

		self[:FOLDERLIST].tie(@models[:FOLDERS])
		self[:FOLDERLIST].target_cursor(@models[:FOLDERS].open_folder('Inbox'))

		self[:SUMMARY].tie(self[:FOLDERLIST].current)
		self[:SUMMARY].target_cursor

		self[:PREVIEW].tie(self[:SUMMARY].current)

		self[:CREATE_FOLDER].tie(@models[:CREATE_FOLDER])

		self[:INC_SEARCH].tie(@models[:INC_SEARCH])

		self[:FTEXT_SEARCH].tie(@models[:FTEXT_SEARCH])

		self[:WIKI_CREATE_PAGE].tie(@models[:WIKI_CREATE_PAGE])

		@stack = []												# ビュー(ウィンドウ)の重なり

		def @stack.activate(view)								# 指定のビューを最上面にする
			self.delete(view)
			self.push(view)										# 最上面はスタックのトップ側
		end

		@stack.activate(:STATUS)								# ビュー(ウィンドウ)の初期の重なり状態を指定
		@stack.activate(:PREVIEW)
		@stack.activate(:SUMMARY)

		@keys = 0

		@actions = {											# 代表ビューが実行できるアクション一覧
			:mk_global_status_scroll_down	=> method(:status_scroll_down),
			:mk_global_status_scroll_up		=> method(:status_scroll_up),
			:mk_global_toggle_what_key		=> method(:toggle_what_key),
		}
	end

	def open
		Curses.init_screen
		Curses.noecho
		Curses.raw
		Curses.clear
		Curses.refresh
	end

	def reopen
		open
	end

	def current
		active.current
	end

	def action(command)
		(it = @actions[command]) ? it.call : nil
	end

	#-----------------------------------------------------------
	#
	#	キー入力待ち、コマンド識別
	#
	def ready(view)
		until(io = IO.select([$stdin, @controller.pipe[MaveController::PIPE_RD]], nil, nil, nil)); end
		$status.log(['IO.select = %s', io.inspect]) if(@what_key)	#### for DEBUG

		prefix = nil; command = nil
		@keys += @key = io[MaveController::SELECT_RD].first.getc
		what = 'key = %-6s, keys = 0x%s' % [@key.chr.inspect, @keys.to_s(16)]
		v = view; while(!(prefix = @@keymaps[v][:PREFIX][@keys]) and v = @@keymaps[v][:PARENT]); end
		if(prefix)
			@keys <<= 8
		else
			v = view; while(!(command = @@keymaps[v][@keys]) and v = @@keymaps[v][:PARENT]); end
			@keys = 0
		end
		what << ', command = ' + command.to_s if(command)
		$status.log(['%s', what]) if(@what_key)
		command
	end

	#-----------------------------------------------------------
	#
	#	 割り込みキー入力待ち、コマンド識別
	#
	def check_interrupt(view)
		interrupts = []
		while(io = IO.select([$stdin], nil, nil, 0))
			key = io[MaveController::SELECT_RD].first.getc
			v = view; while(!(command = @@keymaps[v][key]) and v = @@keymaps[v][:PARENT]); end
			interrupts << (command || key)
		end
		interrupts
	end

	#-----------------------------------------------------------
	#
	#	キー情報の表示、切り替え
	#
	def toggle_what_key
		@what_key = !@what_key
		$status.log(['what key: %s', @what_key.to_s])
	end

	#-----------------------------------------------------------
	#
	#	ステータスウィンドウのスクロール
	#
	def status_scroll_down
		self[:STATUS].scroll_down
	end

	def status_scroll_up
		self[:STATUS].scroll_up
	end

	#-----------------------------------------------------------
	#
	#	フォルダ群を渡す
	#
	def folders
		@models[:FOLDERS]
	end

	#-----------------------------------------------------------
	#
	#	ごみ箱フォルダの確認
	#
	def is_trash?(folder)										# ごみ箱属性を持っているか？
		@models[:ACCOUNTS].each {|account|
			folder.name == account[:TRASH_FOLDER] and return(true)
		}
		false
	end

	def current_trash_folder									# カレントアカウントのごみ箱を返す
		@models[:FOLDERS].each {|folder|
			folder.name == @models[:ACCOUNTS].regular[:TRASH_FOLDER] and return(folder)
		}
		false
	end

	#-----------------------------------------------------------
	#
	#	指定のメッセージ ID を持つメールを返す
	#
	def get_mail_by_message_id(message_id)
		@models[:FOLDERS].each {|folder|
			mail = folder.get_mail_by_message_id(message_id) and return(mail)
		}
		false
	end

	#-----------------------------------------------------------
	#
	#	現在アクティブなビューオブジェクトを返す
	#
	def active
		self[@stack.last]
	end

	#-----------------------------------------------------------
	#
	#	指定のビューオブジェクトを最上面に
	#
	def activate(view)
		if(view == :SUMMARY or view == :PREVIEW)
			vx2 = @screen_x_size / 5 * (view == :SUMMARY ? 4 : 1)
			self[:SUMMARY].resize(vx2 + 1, nil)
			self[:PREVIEW].resize(@screen_x_size - vx2, nil)
			self[:PREVIEW].move(vx2, nil)
		end
		@stack.activate(view)
	end

	#-----------------------------------------------------------
	#
	#	指定のビューオブジェクトを非表示に
	#
	def disable(view)
		@stack.delete(view)
	end

	#-----------------------------------------------------------
	#
	#	各ビューを再構築
	#
	def clean
		cvs = ''
		@stack.each {|view|										# 重なりを考慮して再描画
			self[view].clean
			cvs += view.to_s + ' '
		}
#		$status.log(['clean: %s', cvs])
	end

	#-----------------------------------------------------------
	#
	#	各ビューを再描画
	#
	def update
		uvs = ''
		@stack.each {|view|										# 重なりを考慮して再描画
			self[view].update 
			uvs += view.to_s + ' '
		}
#		$status.log(['update: %s', uvs])
	end

	#-----------------------------------------------------------
	#
	#	ビューを閉じる
	#
	def close
		Curses.close_screen
	end

	#-----------------------------------------------------------
	#
	#	キーマップを設定する
	#
	def self.set_keymaps(keymaps)
		@@keymaps = keymaps
	end
end

#---------------------------------------------------------------
#
#	キー設定ファイルを読み込む
#
load 'mave.keyconfig'
MaveViews.set_keymaps(@mave_keymaps)

#===============================================================================
#
#	ビューの基底クラス
#
class MaveBaseView < Curses::Window

	attr_reader :name

	def initialize(params)
		@name = params[:NAME]
		@views = params[:VIEWS]									# 親ビュー
		@geometry = params[:GEOMETRY]
		super(*(@geometry.reverse))
		move(@geometry[0], @geometry[1])
		resize(@geometry[2], @geometry[3])

		@actions = {}											# ビューが実行できるアクション一覧
	end

	def move(x, y)
		super(y ? @last_y = y : @last_y, x ? @last_x = x : @last_x)
	end

	def resize(w, h)
		super(h ? @last_h = h : @last_h, w ? @last_w = w : @last_w)
		@window_x_size = maxx - 2
		@window_y_size = maxy - 2
	end

	def setpos(x, y)
		super(y + 1, x + 1)
	end

	def clean
	end

	def set_title(title)
		@title = title
	end

	def position												# ポジションインジケータの指定 [min, from, to, max]
		nil
	end

	def update
		box(?|, ?-)
		if(@views.active == self)
			setpos(0, -1); addstr(" #{_(@title || @name.to_s.downcase).decode_cs(@views.charset, 'UTF-8').enspc} ".center(@window_x_size, '='))
		end
		if(p = position)										# ポジションインジケータの描画
			((p[1] - p[0]) * @window_y_size / (vw = p[3] - p[0] + 1)..
			 (p[2] - p[0]) * @window_y_size /  vw).each {|y|
				setpos(@window_x_size, y); addstr('#')
			}
		end
 		setpos(0, @window_y_size)
	end

	def action(command)
		(it = @actions[command]) ? it.call : nil
	end
end

#===============================================================================
#
#	選択ビューの基底クラス
#
class MaveSelectView < MaveBaseView

	attr_reader :items
	attr_reader :current

	def initialize(params)
		super

		@items = []												# 選択対象となるアイテム群
		@nth = 0												# n 番目のアイテムを選択中

		@actions.update({
			:mk_global_previous				=> method(:previous),
			:mk_global_next					=> method(:nekst),
			:mk_global_backward				=> method(:backward),
			:mk_global_forward				=> method(:forward),
			:mk_global_execute				=> method(:execute),
			:mk_global_quit					=> method(:quit),
		})
	end

	def list_items												# 選択可能なアイテム群をリストアップする
		raise
	end

	def target_cursor(value = @current, key = :INSTANCE, missing = 0)	# カーソル位置を指定のアイテムに移動
		@nth = missing; nth = 0
		@items.each {|item|
			@nth = nth and break if(item[key] == value)
			nth += 1
		}
		@current = @nth && @items[@nth][:INSTANCE]
	end

	def target_cursor_reverse(value = @current, key = :INSTANCE, missing = 0)
		@nth = missing; nth = @items.size - 1
		@items.reverse.each {|item|
			@nth = nth and break if(item[key] == value)
			nth -= 1
		}
		@current = @nth && @items[@nth][:INSTANCE]
	end

	def previous
		if(@nth > 0)
			@nth -= 1
			@current = @items[@nth][:INSTANCE]
		end
	end

	def nekst
		if(@nth + 1 < @items.size)
			@nth += 1
			@current = @items[@nth][:INSTANCE]
		end
	end

	def backward
	end

	def forward
	end

	def execute
	end

	def quit
	end

	def clean
		super
	end

	def update
		y = 0
		@items.each {|item|
			break if(y == @window_y_size)
			standout if(y == @nth)
			setpos(0, y); addstr(item[:LABEL].decode_cs(@views.charset, 'UTF-8').snip(@window_x_size).enspc)
			standend
			y += 1
		}
		while(y < @window_y_size)
			setpos(0, y); addstr(' ' * @window_x_size)
			y += 1
		end
		super
	end
end

#===============================================================================
#
#	フォルダリストビュー
#
class MaveFolderListView < MaveSelectView

	def initialize(params)
		@status = params[:STATUS]

		super

		@actions.update({
			:mk_toggle_red					=> method(:toggle_red),
		})
	end

	def tie(folders_model)
		@folders = folders_model								# ビューにモデルを関連づける
		@folders.tie(self, :FOLDERLIST) if(@folders)			# 表示担当モデルに自分を通知する
		list_items
	end

	def list_items
		@items.clear
		@folders.each {|folder|
			@items << {:LABEL => @folders.abstract_of_folder(folder), :INSTANCE => folder}
		}
	end

	def set_callback(proc)
		@callback = proc
	end

	def create_folder
		@views.activate(:CREATE_FOLDER)
	end

	def forward
		execute
	end

	def execute
		@folders.red(@current)
		@views.disable(:FOLDERLIST)
		@callback.call(@current)
	end

	def quit
		@views.disable(:FOLDERLIST)
		@views.activate(:SUMMARY)
	end

	def toggle_red
		@folders.red?(@current) ? @folders.unred(@current) : @folders.red(@current)
	end

	def clean
		if(@folders.dirty?)
			list_items
			target_cursor
		end
		super
	end

	def update
		super
		refresh
	end

	def steal_key(code)
		(it = @folders.shortcuts[code]) ? (@current = it and execute) : nil
	end

	def action(command)
		(it = @actions[command]) ? it.call : (command ? nil : steal_key(@views.key))
	end
end

#===============================================================================
#
#	サマリビュー
#
class MaveSummaryView < MaveSelectView

	def initialize(params)
		@status = params[:STATUS]								# 関連モデル

		@topsq = nil											# 表示先頭のメール連番
		@marks = {}												# メールのマークの処理用

		super

		@actions.update({
			:mk_scroll_down					=> method(:scroll_down),
			:mk_scroll_up					=> method(:scroll_up),

			:mk_beginning_of_summary		=> method(:beginning_of_summary),
			:mk_end_of_summary				=> method(:end_of_summary),

			:mk_global_1st_position			=> method(:_1st_position),
			:mk_global_2nd_position			=> method(:_2nd_position),
			:mk_global_3rd_position			=> method(:_3rd_position),
			:mk_global_4th_position			=> method(:_4th_position),
			:mk_global_5th_position			=> method(:_5th_position),
			:mk_global_6th_position			=> method(:_6th_position),
			:mk_global_7th_position			=> method(:_7th_position),
			:mk_global_8th_position			=> method(:_8th_position),
			:mk_global_9th_position			=> method(:_9th_position),

			:mk_jump_root					=> method(:jump_root),

			:mk_toggle_red					=> method(:toggle_red),
			:mk_toggle_flag					=> method(:toggle_flag),
			:mk_toggle_notice				=> method(:toggle_notice),
			:mk_toggle_fold					=> method(:toggle_fold),
			:mk_toggle_fold_root			=> method(:toggle_fold_root),

			:mk_isearch_forward				=> method(:isearch_forward),
			:mk_isearch_backward			=> method(:isearch_backward),

			:mk_mark						=> method(:mark_mail),
			:mk_unmark						=> method(:unmark_mail),
			:mk_unmark_all					=> method(:unmark_all),

			:mk_join						=> method(:join_mail),
			:mk_unjoin						=> method(:unjoin_mail),
			:mk_rejoin						=> method(:rejoin_mail),

			:mk_global_move					=> method(:move_mail),
			:mk_global_copy					=> method(:copy_mail),
			:mk_global_delete				=> method(:delete_mail),

			:mk_export_mail					=> method(:export_mail),
			:mk_extract_attachments			=> method(:extract_attachments),
			:mi_enclose_attachments			=> method(:enclose_attachments),

			:mk_pop_tag_mark				=> method(:pop_tag_mark),
			:mk_fulltext_search				=> method(:fulltext_search),
			:mk_fulltext_search_all			=> method(:fulltext_search_all),

			:mk_identify_mail				=> method(:identify_mail),

			:mk_wiki_create_page			=> method(:wiki_create_page),
			:mk_wiki_fetch_pages			=> method(:wiki_fetch_pages),
			:mk_wiki_send_page				=> method(:wiki_send_page),
			:mk_wiki_send_pages_all			=> method(:wiki_send_pages_all),
		})
	end

	def tie(folder_model)
		@topsq = nil
		@folder = folder_model									# ビューにモデルを関連づける
		@folder.tie(self, :SUMMARY) if(@folder)					# 表示担当モデルに自分を通知する
		set_title((_(@name.to_s.downcase).force_encoding('UTF-8') + ': ' + folder_model.configs[:LIST_NAME].force_encoding('UTF-8')).enspc)
		list_items
	end

	def jump(sq)
		@topsq = sq
	end

	def list_items
		@items.clear
		wy = 1; @folder.each_sq(@topsq) {|sq, level|
			mail = @folder.get_mail(sq)
			@items << {:LABEL => @folder.abstract_of_mail(sq, mail, @marks, '  ' * level), :INSTANCE => mail, :SQ => sq}
			break if((wy += 1) > @window_y_size)
		} if(@folder)
		@items << {:LABEL => "-- #{_('no mail')} --", :INSTANCE => nil} if(@items.size == 0)
	end

	def target_cursor(value = @current, key = :INSTANCE, missing = 0)	# カーソル位置を指定のアイテムに移動
		instance = super
		@views[:PREVIEW].tie(@current)
		instance
	end

	def previous												# 上方に移動
		if(@nth > 0)
			@nth -= 1
			@current = @items[@nth][:INSTANCE]
			@views[:PREVIEW].tie(@current)
		else
			if(prev_sq = @folder.previous_sq(@items[0][:SQ]))	# 上方に半画面スクロール移動
				y = @window_y_size >> 1
				@folder.reverse_each_sq(@items[0][:SQ]) {|sq, level|
					@topsq = sq
					break if((y -= 1) < 0)
				}
				list_items
				target_cursor(prev_sq, :SQ)
			end
		end
	end

	def nekst													# 下方に移動
		if(@nth + 1 < @items.size)
			@nth += 1
			@current = @items[@nth][:INSTANCE]
			@views[:PREVIEW].tie(@current)
		else
			if(next_sq = @folder.next_sq(@items[@nth][:SQ]))	# 下方に半画面スクロール移動
				@topsq = @items[@window_y_size >> 1][:SQ]
				list_items
				target_cursor(next_sq, :SQ)
			end
		end
	end

	def backward
		callback = Proc.new {|current|							# フォルダ変更
			@views[:SUMMARY].unmark_all
			@views[:SUMMARY].tie(current)
			@views.activate(:SUMMARY)
			@views[:SUMMARY].list_items
			@views[:SUMMARY].target_cursor(nil)
		}
		@views[:FOLDERLIST].set_title(nil)
		@views[:FOLDERLIST].set_callback(callback)
		@views[:FOLDERLIST].target_cursor(@folder)				# FOLDERLIST ビューにカレントフォルダを教える
		@views.activate(:FOLDERLIST)
	end

	def forward
		it = @items[@nth][:SQ] and @folder.red(it)				# メールを既読に
		@views.activate(:PREVIEW)
	end

	def scroll_down												# 上方に 2 行残してスクロール移動
		last_sq = @items[@nth][:SQ]
		y = @window_y_size - 2
		@folder.reverse_each_sq(@items[0][:SQ]) {|sq, level|
			@topsq = sq
			break if((y -= 1) < 0)
		}
		list_items
		target_cursor_reverse(last_sq, :SQ)
	end

	def scroll_up												# 下方に 2 行残してスクロール移動
		if(it = @items[@window_y_size - 2])
			last_sq = @items[@nth][:SQ]
			@topsq = it[:SQ]
			list_items
			target_cursor(last_sq, :SQ)
		end
	end

	def beginning_of_summary
		@topsq = nil
		list_items
		@nth = 0
		@current = @items[@nth][:INSTANCE]
		@views[:PREVIEW].tie(@current) if(@current)
	end

	def end_of_summary
	end

	def _1st_position
		nth_position( 6)
	end
	def _2nd_position
		nth_position(17)
	end
	def _3rd_position
		nth_position(28)
	end
	def _4th_position
		nth_position(39)
	end
	def _5th_position
		nth_position(50)
	end
	def _6th_position
		nth_position(61)
	end
	def _7th_position
		nth_position(72)
	end
	def _8th_position
		nth_position(83)
	end
	def _9th_position
		nth_position(94)
	end
	def nth_position(pos)
		@nth = (pos * (@items.size - 1)) / 100
		@current = @items[@nth][:INSTANCE]
		@views[:PREVIEW].tie(@current)
	end

	def jump_root
		sq = @items[@nth][:SQ]
		root_sq = @folder.get_rootsq_by_sq(sq)
		if(!target_cursor(root_sq, :SQ, nil))					# (カーソル/画面)移動
			@topsq = root_sq
			list_items
			target_cursor(root_sq, :SQ)
		end
	end

	def toggle_red
		if(@marks.size == 0)
			sq = @items[@nth][:SQ]
			@folder.red?(sq) ? @folder.unred(sq) : @folder.red(sq)
		else
			state = @folder.red?(@marks.keys.first)
			@marks.keys.each {|sq|
				state ? @folder.unred(sq) : @folder.red(sq)
			}
		end
		@views.folders.dirty
	end

	def toggle_flag
		if(@marks.size == 0)
			sq = @items[@nth][:SQ]
			@folder.flag?(sq) ? @folder.unflag(sq) : @folder.flag(sq)
		else
			state = @folder.flag?(@marks.keys.first)
			@marks.keys.each {|sq|
				state ? @folder.unflag(sq) : @folder.flag(sq)
			}
		end
	end

	def toggle_notice
		if(@marks.size == 0)
			sq = @items[@nth][:SQ]
			@folder.notice?(sq) ? @folder.unnotice(sq) : @folder.notice(sq)
		else
			state = @folder.notice?(@marks.keys.first)
			@marks.keys.each {|sq|
				state ? @folder.unnotice(sq) : @folder.notice(sq)
			}
		end
	end

	def toggle_fold
		if(@marks.size == 0)
			sq = @items[@nth][:SQ]
			@folder.fold?(sq) ? @folder.unfold(sq) : @folder.fold(sq)
		else
			state = (@folds and @folds > 0) ? true : false		#### 全畳みかどうか確認する
			@folds = 0; @marks.keys.each {|sq|
				state ? @folder.unfold(sq) : @folder.fold(sq)
				@folds += 1 if(@folder.fold?(sq))
			}
		end
	end

	def toggle_fold_root
		sq = @items[@nth][:SQ]
		root_sq = @folder.get_rootsq_by_sq(sq)
		@folder.fold?(root_sq) ? @folder.unfold(root_sq) : @folder.fold(root_sq)
		if(!target_cursor(root_sq, :SQ, nil))					# (カーソル/画面)移動
			@topsq = root_sq
			list_items
			target_cursor(root_sq, :SQ)
		end
		end

	#-------------------------------------- MaveSummaryView ----
	#
	#	インクリメンタル検索ビュー、起動処理
	#
	def isearch_forward
		@views[:INC_SEARCH].set_target_view(self)
		@views[:INC_SEARCH].set_direction(:FORWARD)
		@views.activate(:INC_SEARCH)
	end

	def isearch_backward
		@views[:INC_SEARCH].set_target_view(self)
		@views[:INC_SEARCH].set_direction(:BACKWARD)
		@views.activate(:INC_SEARCH)
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	メール一覧に対する、実際の前方/後方検索処理
	#
	def search_forward(str, skip = 0)
		found_sq = nil; progress = 0
		@folder.each_sq(@items[@nth][:SQ]) {|sq, level|			# 検索
			next if((skip -= 1) > -1)
			yield(progress.to_s) if((progress += 1) % 10 == 0)
			found_sq = sq and break if(@folder.abstract_of_mail_for_search(sq).downcase.index(str.force_encoding('ASCII-8BIT').downcase))
		}
		if(found_sq and !target_cursor(found_sq, :SQ, nil))		# (カーソル/画面)移動
			@topsq = found_sq
			list_items
			target_cursor(found_sq, :SQ)
		end
		found_sq
	end

	def search_backward(str, skip = 0)
		found_sq = nil; progress = 0
		@folder.reverse_each_sq(@items[@nth][:SQ]) {|sq, level|	# 検索
			next if((skip -= 1) > -1)
			yield(progress.to_s) if((progress += 1) % 10 == 0)
			found_sq = sq and break if(@folder.abstract_of_mail_for_search(sq).downcase.index(str.force_encoding('ASCII-8BIT').downcase))
		}
		if(found_sq and !target_cursor(found_sq, :SQ, nil))		# (カーソル/画面)移動
			@topsq = found_sq
			list_items
			target_cursor(found_sq, :SQ)
		end
		found_sq
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	メールのマーク
	#
	def mark_mail
		unless(@folder.fold?(sq = @items[@nth][:SQ]))
			@marks[sq] = @items[@nth][:INSTANCE]
		else
			@folder.each_sq2(sq, 0, 999) {|child_sq, depth|		# 子孫もマーク
				@marks[child_sq] = @folder.get_mail(child_sq)
			}
		end
		nekst
		@folder.dirty
	end

	def unmark_mail
		unless(@folder.fold?(sq = @items[@nth][:SQ]))
			@marks.delete(sq)
		else
			@folder.each_sq2(sq, 0, 999) {|child_sq, depth|		# 子孫もマーク
				@marks.delete(child_sq)
			}
		end
		previous
		@folder.dirty
	end

	def unmark_all
		@marks.clear
		@folder.dirty
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	メールのスレッド関係の操作(結合、独立、再結合)
	#
	def join_mail
		if(@marks.size == 0)
			@status.log([_('Mark mail(s) to be joined.')])
		else
			@marks.keys.sort.each {|sq|
				@folder.join_mail(sq, @items[@nth][:SQ])
			}
			unmark_all
		end
	end

	def unjoin_mail
		if(@marks.size == 0)
			@folder.unjoin_mail(@items[@nth][:SQ])
		else
			@marks.keys.sort.each {|sq|
				@folder.unjoin_mail(sq)
			}
			unmark_all
		end
	end

	def rejoin_mail
		if(@marks.size == 0)
			@folder.rejoin_mail(@items[@nth][:SQ])
		else
			@marks.keys.sort.each {|sq|
				@folder.rejoin_mail(sq)
			}
			unmark_all
		end
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	メールの移動、コピー、削除
	#
	def move_mail(copy = false)									# メールを移動
		if(@marks.size == 0)
			callback = Proc.new {|chosen|
				@topsq = @folder.next_sq(@topsq) if(@items[@nth][:SQ] == @topsq)
				flags = @folder.delete_mail(@items[@nth][:SQ]) unless(copy)	#### 先にファイルを消して問題ない？
				chosen.add_mail(@items[@nth][:INSTANCE], flags)
				@folder.move_related_directory(@items[@nth][:INSTANCE].unique_name, chosen)	#### copy の場合
				@views.activate(:SUMMARY)
			}
		else
			callback = Proc.new {|chosen|
				@marks.keys.sort.each {|sq|
					@topsq = @folder.next_sq(@topsq) if(sq == @topsq)
					flags = @folder.delete_mail(sq) unless(copy)
					chosen.add_mail(@marks[sq], flags)
					@folder.move_related_directory(@marks[sq].unique_name, chosen)
				}
				unmark_all
				@views.activate(:SUMMARY)
			}
		end														#### フラグ(既読等)を保持
		@views[:FOLDERLIST].set_title(copy ? 'Copy to' : 'Move to')
		@views[:FOLDERLIST].set_callback(callback)
		@views[:FOLDERLIST].target_cursor(@folder)				# FOLDERLIST ビューにカレントフォルダを教える
		@views.activate(:FOLDERLIST)
	end

	def copy_mail												# メールをコピー
		move_mail(true)
	end

	def delete_mail												# メールを削除
		trash_folder = @views.is_trash?(@folder) ? nil : @views.current_trash_folder
		if(@marks.size == 0)
			@topsq = @folder.next_sq(@topsq) if(@items[@nth][:SQ] == @topsq)
			flags = @folder.delete_mail(@items[@nth][:SQ])
			trash_folder.add_mail(@items[@nth][:INSTANCE], flags) if(trash_folder)
			@folder.move_related_directory(@items[@nth][:INSTANCE].unique_name, trash_folder)
		else
			@marks.keys.sort.each {|sq|
				@topsq = @folder.next_sq(@topsq) if(sq == @topsq)
				flags = @folder.delete_mail(sq)
				trash_folder.add_mail(@marks[sq], flags) if(trash_folder)
				@folder.move_related_directory(@marks[sq].unique_name, trash_folder)
			}
			unmark_all
		end
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	メールをエクスポートする
	#
	def export_mail
		unless(result = @folder.export_mail(@current))
			@status.log([_('Export mail. file=[%s]'), @current.path.gsub(/.*\//, '')])
		else
			@status.log([_('Failed to export mail. file=[%s] reason=[%s]'), @current.path.gsub(/.*\//, ''), result])
		end
	end
	#-------------------------------------- MaveSummaryView ----
	#
	#	メールの添付ファイルをすべて展開する
	#
	def extract_attachments
		@folder.extract_attachments(@current) {|result, part|
			if(result)
				@status.log([_('Extracted attached file. file=[%s]'), part[:FILENAME]])
			else
				@status.log([_('Skipped to extract attached file. file=[%s] reason=[File exist]'), part[:FILENAME]])
			end
		}
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	メールに添付ファイルを入れ込む
	#
	def enclose_attachments
		@folder.enclose_attachments(@current)
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	タグジャンプから戻る
	#
	def pop_tag_mark
		@views[:PREVIEW].pop_tag_mark
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	全文検索ビュー、起動処理
	#
	def fulltext_search(all = false)
		callback = Proc.new {|mail|
			mail.folder.red(mail.sq)
			@views.activate(:PREVIEW)
			@views[:PREVIEW].tagjump({:VIEW => :PREVIEW, :MESSAGE_ID => mail.message_id, :LINE => nil},
				{:VIEW => :SUMMARY, :SUMMARY_TOP => @items[0][:INSTANCE].message_id, :MESSAGE_ID => @current.message_id, :LINE => @views[:PREVIEW].current_line + 1})
		}
		(it = @views[:FTEXT_SEARCH]).set_title(it.name.to_s.downcase + (all ? ' all' : ''))
		it.set_callback(callback)
		it.set_target_folder(all ? :ALL : @folder)
		@views.activate(:FTEXT_SEARCH)
	end
	def fulltext_search_all
		fulltext_search(true)
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	外部 Wiki のページを新規作成する
	#
	def wiki_create_page
		callback = Proc.new {|title|
			@folder.methods.include?(:create_wiki_page) or raise('no method')
			page = @folder.create_wiki_page(title) or raise('disabled')
			wiki_fetch_page(page)
		}
		@views[:WIKI_CREATE_PAGE].set_callback(callback)
		@views.activate(:WIKI_CREATE_PAGE)
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	外部 Wiki の全ページを取得する
	#
	def wiki_fetch_pages
		begin
			@folder.methods.include?(:fetch_wiki_index) or raise('no method')
			@status.log([_('Connecting Wiki...')])
			index = @folder.fetch_wiki_index or raise('disabled')
			@status.log([_("Connected Wiki '%s'."), index[0]])
			n_page = 0; p_page = 0; max_n_page = index[1].size
			index[1].sort {|a, b| a[:TIME] <=> b[:TIME] }.each {|page|
				n_page += 1
				mail = @folder.get_mail_by_message_id(page[:MESSAGE_ID])
				mail and mail.date == page[:TIME] and next		# タイムスタンプが同じなら何もしない
#				if(mail)	# 更新が衝突したら、時刻を見て同期処理？
#					@status.log(['== mail overwrite [%s: mail: %s, list: %s] ==', (mail.date == page[:TIME]), mail.date.inspect, page[:TIME].inspect])
#					@folder.overwrite_mail(mail, old_mail)
#					next
#				end
				wiki_fetch_page(page)
				p_page += 1
				@status.log([_('Picked (%1$d/%2$d) [%3$s] [%4$s]'),
					n_page, max_n_page, page[:TIME].mystrftime(false), page[:TITLE]])
			}
			result_message = (it = p_page) != 0 ? '%1$s page%2$s picked.(%3$s)' : 'no pages picked.(%3$s)'
			@status.log([_(result_message), it.to_s, it == 1 ? '' : 's', Time.now.myexectime])
#		rescue
#			case($!.message)
#			when('not provided');	@status.log([_('Function not provided yet.')])
#			else;					@status.log([_('Unexpected error occurred. reason=[%1$s]'), $!.message.split(/\r?\n/)[0]])
#			end
		end
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	外部 Wiki のページを取得する
	#
	def wiki_fetch_page(page)
		begin
			@folder.methods.include?(:fetch_wiki_page) or raise('no method')
			results = @folder.fetch_wiki_page(page) or raise('disabled')
			header = {}
			header['Subject'] = page[:TITLE]
			header['Date'] = page[:TIME].rfc2822
			header['Message-id'] = page[:MESSAGE_ID]

			header['X-Mave-Store-Folder'] = @folder.name
			header['X-Mave-Overwrite-Mail'] = 'True'

			results[:INPUTS].each {|k, v|
				header['X-Mave-Wiki-Cgi-%s' % k] = v
			}
			results[:COOKIES].each {|k, v|
				header['X-Mave-Wiki-Cookie-%s' % k] = v
			}
			@views.controller.generate_mail(header, [], results[:CONTENTS])
		rescue
			@status.log([_('Unexpected error occurred. reason=[%1$s]'), $!.message.split(/\r?\n/)[0]])
		end
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	外部 Wiki のページを更新する
	#
	def wiki_send_page(mail = @current)
		begin
			@folder.methods.include?(:send_wiki_page) or raise('no method')
			request = {}; request[:COOKIES] = {}; request[:CONTENTS] = []
			mail.header.each {|k, v|
				k =~ /^X-mave-wiki-cgi-(.*)/ and request[$1] = v
				k =~ /^X-mave-wiki-cookie-(.*)/ and request[:COOKIES][$1] = v
			}
			mail.body_each {|line|
				request[:CONTENTS] << line.chomp
			}

			results = @folder.send_wiki_page(request) or raise('disabled')	# 更新実行

			@status.log([_('Update (%1$d/%2$d) [%3$s] [%4$s]'), 1, 1, results[:CODE], mail.subject.decode_mh])
			it = results[:BODY] and it.each {|l|	# 499 なら内容をメール化
				@status.log(['  == %s ==', l])
			}
#		rescue
#			case($!.message)
#			when('not provided');	@status.log([_('Function not provided yet.')])
#			when('no method');		@status.log([_('The folder has no full-text search method.')])
#			when('disabled');		@status.log([_('The full-text search method has disabled.')])
#			else;					@status.log([_('Unexpected error occurred. reason=[%1$s]'), $!.message.split(/\r?\n/)[0]])
#			end
		end
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	外部 Wiki のページをすべて更新する
	#
	def wiki_send_pages_all
		@status.log(['==hiki== save_pages_all ===='])
		@folder.reverse_each_sq {|sq, level|
			mail = @folder.get_mail(sq)
			@status.log(['==hiki== %d ====', sq])
#			wiki_send_page(mail)
		}
	end

	#-------------------------------------- MaveSummaryView ----
	#
	#	メールの詳細情報を表示する
	#
	def identify_mail
		@status.log(['==== ' + _('Mail Identification') + ' ===='])
		if(@current)
			@current.identify {|id|
				@status.log(id)
			}
		else
			@status.log([_('Mail not selected.')])
		end
	end

	def clean
		if(@folder.dirty?)
			list_items
			item = nil; (0..@nth).each {|n|						# カーソル位置の項目消失なら、上に持ち上げる
				break if(item = @items[@nth - n])
			}
			target_cursor(item[:SQ], :SQ)						#### ページ外だと対応できない
		end
		super
	end

	def position												# ポジションインジケータの指定 [min, from, to, max]
		[0, @nth, @nth, @folder.flags_sq.get_n.to_i]
	end

	def update
		super
		refresh
	end
end

#===============================================================================
#
#	プレビュービュー
#
class MavePreviewView < MaveBaseView

	def initialize(params)
		@clip = params[:CLIP]									# 関連モデル
		@status = params[:STATUS]

		@topline = 0											# 表示先頭のメール行番号
		@cur_pos = 15											# カーソルの位置(オフセット)

		@tagstack = []											# タグジャンプからの戻り用スタック

		@separator = ''; (1..26).each {|n|
			@separator << '====+====%d' % (n % 10)
		}

		super

		@actions.update({
			:mk_global_previous				=> method(:previous),
			:mk_global_next					=> method(:nekst),
			:mk_global_backward				=> method(:backward),
			:mk_global_forward				=> method(:forward),
			:mk_global_execute				=> method(:execute),
			:mk_global_quit					=> method(:quit),

			:mk_scroll_down					=> method(:scroll_down),
			:mk_scroll_up					=> method(:scroll_up),

			:mk_beginning_of_message		=> method(:beginning_of_message),
			:mk_end_of_message				=> method(:end_of_message),

			:mk_isearch_forward				=> method(:isearch_forward),
			:mk_isearch_backward			=> method(:isearch_backward),

			:mk_toggle_red					=> method(:toggle_red),
			:mk_toggle_flag					=> method(:toggle_flag),
			:mk_toggle_notice				=> method(:toggle_notice),

			:mk_global_delete				=> method(:delete_mail),

			:mk_extract_attachment			=> method(:extract_attachment),

			:mk_clip						=> method(:clip),
			:mk_append_next_clip			=> method(:append_next_clip),
#			:mk_yank						=> method(:yank),
			:mk_find_tag					=> method(:find_tag),
			:mk_pop_tag_mark				=> method(:pop_tag_mark),

			:mk_shell_command				=> method(:shell_command),

			:mk_fulltext_search				=> method(:fulltext_search),
			:mk_fulltext_search_all			=> method(:fulltext_search_all),

			:mk_identify_mail				=> method(:identify_mail),
		})
	end

	def tie(mail_model)
		unless(@mail and mail_model and @mail.sq == mail_model.sq)
			@topline = 0
			@mail = mail_model									# ビューにモデルを関連づける
			@mail.tie(self, :PREVIEW) if(@mail)					# 表示担当モデルに自分を通知する
		end
	end

	def untie
		@mail = nil
	end

	def current
		@mail
	end

	def current_line
		@topline + @cur_pos
	end

	def previous												# 上方に移動
		@topline -= 1 if(@mail and @topline > -@cur_pos)
	end

	def nekst													# 下方に移動
		@topline += 1 if(@mail and @mail[@topline + @cur_pos + 1])
	end

	def backward
		@views.activate(:SUMMARY)
	end

	def forward
	end

	def execute
	end

	def quit
	end

	def scroll_down												# 上方にスクロール移動
		@topline -= (@window_y_size - @abstract_y_size - 2)
		@topline = -@cur_pos unless(@mail and @mail[@topline + @cur_pos])
	end

	def scroll_up												# 下方にスクロール移動
		@topline += (@window_y_size - @abstract_y_size - 2)
		@topline -= 1 while(@mail and !@mail[@topline + @cur_pos])
	end

	def beginning_of_message
		@topline = 0
	end

	def end_of_message
	end

	def toggle_red
		(it = @mail.folder).red?(sq = @mail.sq) ? it.unred(sq) : it.red(sq)
	end

	def toggle_flag
		(it = @mail.folder).flag?(sq = @mail.sq) ? it.unflag(sq) : it.flag(sq)
	end

	def toggle_notice
		(it = @mail.folder).notice?(sq = @mail.sq) ? it.unnotice(sq) : it.notice(sq)
	end

	#-------------------------------------- MavePreviewView ----
	#
	#	インクリメンタル検索ビュー、起動処理
	#
	def isearch_forward
		@views[:INC_SEARCH].set_target_view(self)
		@views[:INC_SEARCH].set_direction(:FORWARD)
		@views.activate(:INC_SEARCH)
	end

	def isearch_backward
		@views[:INC_SEARCH].set_target_view(self)
		@views[:INC_SEARCH].set_direction(:BACKWARD)
		@views.activate(:INC_SEARCH)
	end

	#-------------------------------------- MavePreviewView ----
	#
	#	メール本文に対する、実際の前方/後方検索処理				#### とりあえず冗長に書いておく
	#
	def search_forward(str, skip = 0)
		found_n = nil; progress = skip
		@mail.body_each(@topline + @cur_pos + skip) {|line|		# 検索
			found_n = progress and break if(line.downcase.index(str.downcase))	# mail) =~ /#{str}/i)
			yield(progress) if((progress += 1) % 10 == 0)
		} if(@mail)
		@topline += found_n if(found_n)							# (カーソル/画面)移動
	end

	def search_backward(str, skip = 0)
		found_n = nil; progress = skip
		@mail.body_reverse_each(@topline + @cur_pos - skip) {|line|		# 検索
			found_n = progress and break if(line.downcase.index(str.downcase))	# mail) =~ /#{str}/i)
			yield(progress) if((progress += 1) % 10 == 0)
		} if(@mail)
		@topline -= found_n if(found_n)							# (カーソル/画面)移動
	end

	#-------------------------------------- MavePreviewView ----
	#
	#	メールの移動、コピー、削除
	#
#	def move_mail(copy = false)									# メールを移動
#	def copy_mail												# メールをコピー
	def delete_mail												# メールを削除
		trash_folder = @views.is_trash?(@mail.folder) ? nil : @views.current_trash_folder
		flags = @mail.folder.delete_mail(@mail.sq)
		trash_folder.add_mail(@mail, flags) if(trash_folder)
		@mail.folder.move_related_directory(@mail.unique_name, trash_folder)
	end

	#-------------------------------------- MavePreviewView ----
	#
	#	指定のメールの添付ファイルを展開する
	#
	def extract_attachment
		@mail.folder.extract_attachments(@mail, @topline + @cur_pos) {|result, part|
			if(result)
				@status.log([_('Extracted attached file. file=[%s]'), part[:FILENAME]])
			else
				@status.log([_('Skipped to extract attached file. file=[%s] reason=[File exist]'), part[:FILENAME]])
			end
		}
	end

	#-------------------------------------- MavePreviewView ----
	#
	#	メールの切り抜きを作る／貼る
	#
	def clip(append = false)
		unless(@last_clip_message_id == @mail.message_id)		# clip 対象のメールが前回と異なる
			@clip.rotate unless(append)
			@clip.clip_header(@mail, @topline + @cur_pos)
			@last_clip_message_id = @mail.message_id
		end
		@clip.clip_body(@mail, @topline + @cur_pos)
		nekst
	end

	def append_next_clip
		clip(true)
	end

#	def yank
#		@clip.open {|fh|										# PseudoMail をオープンして、書き戻す ※未実装
#			fh.each {|line|
#				@status.log([_('yank: %s'), line.chomp.decode_mh])
#			}
#		}
#	end

	#-------------------------------------- MavePreviewView ----
	#
	#	カーソル行のシェルコマンドの実行結果をメール化する
	#
	def shell_command
		command = @mail[@topline + @cur_pos]
		command.gsub!(/%%self_filename%%/, @mail.path)
		folder = @mail.folder
		IO.popen(command) {|stdout|
			results = MaveMail.new({:FILE => stdout})			# ヘッダを MaveMail に解析させる
			it = results.header['X-mave-store-folder'] and folder = (it != '%%drop%%') ? @views.folders.open_folder(it) : false
			folder.create_mail_shell_command(results.header, results.heads, stdout) if(folder)
		}
		folder	? @status.log([_('Shell command was executed. Result was stored in the [%s] folder.'), folder.name]) \
				: @status.log([_('Shell command was executed. Result was dropped.')])
	end

	#-------------------------------------- MavePreviewView ----
	#
	#	タグジャンプを行う
	#
	def tagjump(to, from = nil)
		if(mail = @views.get_mail_by_message_id(to[:MESSAGE_ID]))
			top_mail = @views.get_mail_by_message_id(to[:SUMMARY_TOP]) || mail
			@tagstack << from if(from)							# 現地点をタグスタックに積む
			@views[:SUMMARY].unmark_all
			@views[:SUMMARY].tie(mail.folder)
			mail.folder.unfold_parents(mail.sq)					# 対象メールの折りたたみ状態を解除
			@views[:SUMMARY].jump(top_mail.sq)					# タグジャンプ
			@views[:SUMMARY].list_items
			@views[:SUMMARY].target_cursor(mail.sq, :SQ)
			if(it = to[:LINE])
				@topline = it.to_i - @cur_pos - 1
				(0..@topline).each {|n| @mail[n] }				#### なぜか、事前になめる必要あり
			end
			@views.activate(to[:VIEW])
		else
			@status.log([_('Target tag was not found.')])
		end
	end

	def find_tag
		filename = message_id = sup = nil
		[0, 1, -1, 2, -2, 3, -3, 4, -4].each {|n|				# ±4 行の範囲のタグを探す
			tag = @mail[@topline + @cur_pos + n]
			tag =~ %r|file://(/\S+)\s+(.*)| and filename = $1 and sup = $2 and break
			tag =~ /(<[^>]+>)\s+(.*)/ and message_id = $1 and sup = $2 and break
			tag =~ %r|(https?://\S+)| and `opera #{$1}` and return	# とりあえず
		}
		filename and begin
			mailfile = File.new(filename) rescue raise('Target file was not found.')
			message_id = MaveMail.new({:FILE => mailfile}).message_id rescue raise('Target mail format was not correct.')
		rescue
			@status.log([_($!.message)]); return
		end
		if(message_id)
			tagjump({:VIEW => :PREVIEW, :MESSAGE_ID => message_id, :LINE => (sup =~ /line:(\d+)/) ? $1.to_i : nil},	# current_line
				{:VIEW => :PREVIEW, :SUMMARY_TOP => @views[:SUMMARY].items[0][:INSTANCE].message_id, :MESSAGE_ID => @mail.message_id, :LINE => @topline + @cur_pos + 1})
		else
			@status.log([_('Tag was not found.')])
		end
	end

	def pop_tag_mark
		if(tag = @tagstack.pop)
			tagjump(tag)
		else
			@status.log([_('Tagstack was empty.')])
		end
	end

	#-------------------------------------- MavePreviewView ----
	#
	#	全文検索ビュー、起動処理
	#
	def fulltext_search(all = false)
		tag = @mail[@topline + @cur_pos]
		unless(tag =~ /^fulltext_search\s+/)					# 初回検索
			callback = Proc.new {|mail|
				mail.folder.red(mail.sq)
				@views[:PREVIEW].tagjump({:VIEW => :PREVIEW, :MESSAGE_ID => mail.message_id, :LINE => nil},	#### summary に戻ってしまう
					{:VIEW => :PREVIEW, :SUMMARY_TOP => @views[:SUMMARY].items[0][:INSTANCE].message_id, :MESSAGE_ID => @mail.message_id, :LINE => @topline + @cur_pos + 1})
			}
			(it = @views[:FTEXT_SEARCH]).set_title(it.name.to_s.downcase + (all ? ' all' : ''))
			it.set_callback(callback)
			it.set_target_folder(all ? :ALL : @mail.folder)
			@views.activate(:FTEXT_SEARCH)
		else													# 次検索
			callback = Proc.new {|mail|
				mail.folder.red(mail.sq)
				@views[:PREVIEW].tagjump({:VIEW => :PREVIEW, :MESSAGE_ID => mail.message_id, :LINE => nil})
			}
			params = {}; tag.scan(/(\S+)=(['"])(.+?)\2/) {|p| params[p[0].to_sym] = p[2] }
			it = @views[:FTEXT_SEARCH]
			it.set_callback(callback)
			it.set_target_folder(all ? :ALL : @views.folders.open_folder(params[:FOLDER], false))
			it.execute(params)
		end
	end
	def fulltext_search_all
		fulltext_search(true)
	end

	#-------------------------------------- MavePreviewView ----
	#
	#	メールの詳細情報を表示する
	#
	def identify_mail
		@status.log(['==== ' + _('Mail Identification') + ' ===='])
		if(@mail)
			@mail.identify {|id|
				@status.log(id)
			}
		else
			@status.log([_('Mail not selected.')])
		end
	end

	def clean
		super
	end

	def position
		[0, 0, 0, 10000]
	end

	def update
		y = max_fold = nil

		d0 = Proc.new {|line, on_cursor|						# カーソル行をハイライト
			standout if(on_cursor)
			line.decode_cs(@views.charset, 'UTF-8').each_snip(@window_x_size, max_fold) {|line0|
				break unless(y < @window_y_size)
				setpos(0, y); addstr(line0.enspc)
				y += 1
			}
			standend
			y < @window_y_size
		}

		d1 = Proc.new {|line, on_cursor|						# カーソル行の左に「]」マーク
			mark = on_cursor ? ']' : ' '
			line.decode_cs(@views.charset, 'UTF-8').each_snip(@window_x_size - 1, max_fold) {|line0|
				break unless(y < @window_y_size)
				setpos(0, y); addstr(mark + line0.enspc) rescue true	# NULL が含まれる場合がある
				y += 1
			}
			y < @window_y_size
		}

		y = 0; max_fold = 1
		if(@mail)
			it = @mail.pseudo_from			and d0.call(_('   From: ') + it, nil)
			it = @mail.pseudo_to			and d0.call(_('     To: ') + it, nil)
			it = @mail.pseudo_cc			and d0.call(_('     Cc: ') + it, nil)
			it = @mail.subject.decode_mh	and d0.call(_('Subject: ') + it, nil)
			d0.call(@separator, nil); @abstract_y_size = y
			max_fold = 9999; cur_nth = @topline + @cur_pos
			(@topline..@topline + 9999).each {|nth|
				d0.call('~') and next if(nth < 0)
				line = @mail[nth] or break
####			d1.call(line.chomp.gsub(/[\x00-\x1F]/, '^x'), nth == cur_nth) or break
				d1.call(line.to_s.chomp, nth == cur_nth) or break
			}
		else
			d1.call("-- #{_('no mail')} --", true)
		end
		loop {
			d0.call('~') or break
		}
		super
		refresh
	end
end

#===============================================================================
#
#	行入力ビューの基底クラス
#
class MaveTextBoxView < MaveBaseView

	def initialize(params)
		@status	= params[:STATUS]								# 関連モデル

		super

		@prompt = '> '

		@actions.update({
			:mk_delete_backward_char		=> method(:delete_backward_char),
			:mk_clear_textbox				=> method(:clear),
			:mk_global_execute				=> method(:execute),
			:mk_global_quit					=> method(:quit),
		})
	end

	def set_prompt(prompt)
		@prompt = prompt.force_encoding('ASCII-8BIT')
	end

	def delete_backward_char
		@textbox.delete_backward_char
	end

	def clear
		@textbox.clear
	end

	def update
		super
		setpos(0, 0); addstr((l = (@prompt + @textbox.text).decode_cs(@views.charset, 'UTF-8')).snip(@window_x_size).enspc)
		setpos(l.wsize, 0)
	end

	def steal_key(code)
		@textbox.key_entry(code)
	end

	def action(command)
		(it = @actions[command]) ? it.call : steal_key(@views.key)
		nil														# コマンド/キーを受け取っていないふり
	end
end

#===============================================================================
#
#	新規フォルダ名入力ビュー
#
class MaveCreateFolderView < MaveTextBoxView

	def initialize(params)
		super

		set_prompt(_('Folder name: '))

		@actions.update({
		})
	end

	def tie(create_folder_model)
		@textbox = create_folder_model							# ビューにモデルを関連づける
		@textbox.tie(self, :CREATE_FOLDER) if(@textbox)			# 表示担当モデルに自分を通知する
	end

	def execute
		@textbox.create_folder									#### 要エラー処理、禁則文字チェック
		@status.log([_('Folder [%s] created.'), @textbox.text])
		@textbox.clear
		@views.disable(:CREATE_FOLDER)
	end

	def quit
		@status.log([_('Aborted.')])
		@textbox.clear
		@views.disable(:CREATE_FOLDER)
	end

	def update
		super
		refresh
	end
end

#===============================================================================
#
#	インクリメンタル検索ビュー
#
class MaveIncrementalSearchView < MaveTextBoxView

	def initialize(params)
		super

		@actions.update({
			:mk_isearch_forward				=> method(:isearch_forward),
			:mk_isearch_backward			=> method(:isearch_backward),
		})
	end

	def tie(inc_search_model)
		@textbox = inc_search_model								# ビューにモデルを関連づける
		@textbox.tie(self, :INC_SEARCH) if(@textbox)			# 表示担当モデルに自分を通知する
	end

	def set_target_view(view)									# 検索対象を受け取る
		@target_view = view
	end

	def set_direction(direction)
		@direction = direction
		change_prompt(['', _(@direction == :BACKWARD ? ' backward' : ''), ''])
	end

	def change_prompt(ps)
		@views[:INC_SEARCH].set_prompt(_('%1$sI-search%2$s: %3$s') % ps)
	end

	#---------------------------- MaveIncrementalSearchView ----
	#
	#	メール本文に対する、実際の前方/後方検索処理
	#
	def isearch_forward(skip = 1)								#### 要、無駄な再検索の抑制
		ps = ['', '', '']
		set_direction(:FORWARD)
		func = @target_view.method(:search_forward)
		isearch(func, skip, ps)
	end

	def isearch_backward(skip = 1)
		ps = ['', _(' backward'), '']
		set_direction(:BACKWARD)
		func = @target_view.method(:search_backward)
		isearch(func, skip, ps)
	end

	def isearch(func, skip, ps)
		begin
			(@last_hit ? @textbox.set_text(@last_hit) : raise('no target')) if(@textbox.text.size == 0)
			found = func.call(@textbox.utf8_text, skip) {|progress|	#### 暫定
				@views[:INC_SEARCH].set_prompt(_('Searching...%s: ') % progress); update
				@views.check_interrupt(:INTERRUPT).each {|code|
					raise('abort') if(code == :mk_global_quit)
					@textbox.key_entry(code)
				}
#				sleep 0.1										#### for DEBUG
			}
			found ? (@last_hit = @textbox.text.dup) : (ps[0] = _('Failing '))
		rescue RuntimeError
			$!.message == 'abort' ? (ps[0] = _('Aborting ')) : (ps[2] = _('[No previous search string]'))
		end
		change_prompt(ps)
	end

	def execute
		@direction == :FORWARD ? isearch_forward : isearch_backward
	end

	def quit
		@textbox.clear
		@views.disable(:INC_SEARCH)
	end

	def update
		super
		refresh
	end

	def steal_key(code)											# 文字の追加
		@textbox.key_entry(code)
		@direction == :FORWARD ? isearch_forward(0) : isearch_backward(0)
	end
end

#===============================================================================
#
#	全文検索クエリ入力ビュー
#
class MaveFulltextSearchQueryView < MaveTextBoxView

	def initialize(params)
		super

		set_prompt(_('Fulltext-search: '))

		@actions.update({
		})
	end

	def tie(ftext_search_model)
		@textbox = ftext_search_model							# ビューにモデルを関連づける
		@textbox.tie(self, :FTEXT_SEARCH) if(@textbox)			# 表示担当モデルに自分を通知する
	end

	def set_callback(proc)
		@callback = proc
	end

	def set_target_folder(folder)								# 検索対象フォルダを受け取る
		@target_folder = folder
	end

	def execute(params = {})
		sq = nil
		begin
			@target_folder == :ALL and raise('not provided')
			@target_folder.methods.include?(:fulltext_search) or raise('no method')
			folder = nil
			params[:QUERY] ||= @textbox.text
			results = @target_folder.fulltext_search(params) or raise('disabled')	# 検索実行
			def results.each
				self[:ITEMS].each {|item|
					yield('■%d. %s' % [item[:N], item[:TITLE]]);	yield('')
					yield(item[:SNIPPET]);							yield('')	#### 字下げ＆改行を入れたい
					yield(item[:URI]);								yield('');	yield('')
				}
				yield("fulltext_search FOLDER='%s' QUERY='%s' SKIP='%d' MESSAGE_ID='%s'" % [self[:TARGET_FOLDER], self[:QUERY], self[:NEXT_SKIP], self[:MESSAGE_ID]])
			end
			it = results[:STORE_FOLDER] and folder = (it != '%%drop%%') ? @views.folders.open_folder(it) : false
			header = {}
			from = to = 0 and (it = results[:ITEMS]).size > 0 and from = it.first[:N] and to = it.last[:N]
			header['Subject'] = "Search Result: %d - %d of %d for '%s'" % [from, to, results[:HIT], params[:QUERY]]
			header['Message-id'] = results[:MESSAGE_ID]
			header['In-reply-to'] = params[:MESSAGE_ID]
			sq = folder.create_mail_shell_command(header, [], results) if(folder)
			folder	? @status.log([_('Full-text search was executed. Result was stored in the [%s] folder.'), folder.name]) \
					: @status.log([_('Full-text search was executed. Result was dropped.')])
		rescue
			case($!.message)
			when('not provided');	@status.log([_('Function not provided yet.')])
			when('no method');		@status.log([_('The folder has no full-text search method.')])
			when('disabled');		@status.log([_('The full-text search method has disabled.')])
			else;					@status.log([_('Unexpected error occurred. reason=[%1$s]'), $!.message.split(/\r?\n/)[0]])
			end
		end
		@textbox.clear
		@views.disable(:FTEXT_SEARCH)
		@callback.call(folder.get_mail(sq)) if(sq)
	end

	def quit
		@textbox.clear
		@views.disable(:FTEXT_SEARCH)
	end

	def update
		super
		refresh
	end
end

#===============================================================================
#
#	外部 Wiki の新規作成ページ名入力ビュー
#
class MaveWikiCreatePageView < MaveTextBoxView

	def initialize(params)
		super

		set_prompt(_('Wiki page name: '))

		@actions.update({
		})
	end

	def tie(wiki_create_page_model)
		@textbox = wiki_create_page_model						# ビューにモデルを関連づける
		@textbox.tie(self, :WIKI_CREATE_PAGE) if(@textbox)		# 表示担当モデルに自分を通知する
	end

	def set_callback(proc)
		@callback = proc
	end

	def execute
		@callback.call(@textbox.text)
		@status.log([_('Wiki new page [%s] created.'), @textbox.text])
		@textbox.clear
		@views.disable(:WIKI_CREATE_PAGE)
	end

	def quit
		@status.log([_('Aborted.')])
		@textbox.clear
		@views.disable(:WIKI_CREATE_PAGE)
	end

	def update
		super
		refresh
	end
end

#===============================================================================
#
#	ステータスビュー
#
class MaveStatusView < MaveBaseView

	def initialize(params)
		@back = 0
		@step = 3

		super
	end

	def tie(status_model)
		@status = status_model									# ビューにモデルを関連づける
		@status.tie(self, :STATUS) if(@status)					# 表示担当モデルに自分を通知する
	end

	def clean
		super
	end

	def scroll_down(step = @step)								# 上方にスクロール移動
		@back += step
	end

	def scroll_up(step = @step)									# 下方にスクロール移動
		@back -= step
		@back = 0 if(@back < 0)
	end

	def head													# 先端に移動
		@back = 0
	end

	def update
		y = -1; @status.recent_each(@window_y_size, @back) {|line|
			setpos(0, y += 1); addstr((line || '~').decode_cs(@views.charset, 'UTF-8').snip(@window_x_size).enspc)
		}
		super
		setpos(2, @window_y_size) & addstr(' vvv ') unless(@back == 0)
		setpos(@window_x_size - (it = @status.aplname).size - 4, @window_y_size); addstr(" #{it} ")
		refresh
	end
end

__END__

