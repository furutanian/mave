FROM docker.io/furutanian/hyperestraier

LABEL 'maintainer=Furutanian <furutanian@gmail.com>'

ARG TZ
ARG http_proxy
ARG https_proxy

RUN set -x \
	&& dnf install -y \
		httpd \
		ruby \
		sudo \
		qdbm \
		ruby-qdbm \
		rubygems \
		ruby-devel \
		gcc \
		redhat-rpm-config \
		ncurses-devel \
		make \
		findutils \
		git \
		procps-ng \
		net-tools \
	&& rm -rf /var/cache/dnf/* \
	&& dnf clean all \
	&& gem install curses

# git clone mave しておくこと
COPY mave /var/www/html
RUN cat /var/www/html/dot.htaccess \
		| sed 's/\(Action.*rhtml-script\)\(.*maverick\)/\1 \//' \
		> /var/www/html/.htaccess

RUN set -x \
	&& mv /etc/httpd/conf/httpd.conf /etc/httpd/conf/httpd.conf.org \
	&& cat /etc/httpd/conf/httpd.conf.org \
		| sed '/^<Directory "\/var\/www\/html">/,/^</s/^\(\s*Options\).*/\1 All/' \
		| sed '/^<Directory "\/var\/www\/html">/,/^</s/^\(\s*AllowOverride\).*/\1 All/' \
		> /etc/httpd/conf/httpd.conf \
	&& diff -C 2 /etc/httpd/conf/httpd.conf.org /etc/httpd/conf/httpd.conf \
	|| echo '/etc/httpd/conf/httpd.conf changed.'
RUN systemctl enable httpd

EXPOSE 80

# Dockerfile 中の設定スクリプトを抽出するスクリプトを出力、実行
COPY Dockerfile .
RUN echo $'\
cat Dockerfile | sed -n \'/^##__BEGIN0/,/^##__END0/p\' | sed \'s/^#\s*//\' > startup.sh\n\
cat Dockerfile | sed -n \'/^##__BEGIN1/,/^##__END1/p\' | sed \'s/^#\s*//\' > crontab.index\n\
' > extract.sh && bash extract.sh

# docker-compose up の最後に実行される設定スクリプト
##__BEGIN0__startup.sh__
#
#	ln -v -fs ../usr/share/zoneinfo/$TZ /etc/localtime
#	crontab crontab.index
#	crontab -l
#
#	mkdir -v -p /var/lib/pv/mave/conf
#	mkdir -v -p /var/lib/pv/mave/mave.mails
#
#	chown -v apache:apache /var/lib/pv/mave/mave.mails
#	if [ ! -e /var/lib/pv/mave/conf/mave.config ]; then
#		cat /var/www/html/mave.config.sample \
#			| sed 's!\(^@configs\[:ROOT_DIRECTORY\].*= \).*!\1"/var/lib/pv/mave/mave.mails"!' \
#			> /var/lib/pv/mave/conf/mave.config
#		diff -C 2 /var/www/html/mave.config.sample /var/lib/pv/mave/conf/mave.config
#	fi
#	ln -v -s /var/lib/pv/mave/conf/mave.config /var/www/html
#
#	mkdir -v -p /var/lib/pv/mave/mave.mails/Inbox
#	chown -v apache:apache /var/lib/pv/mave/mave.mails/Inbox
#	cd /var/lib/pv/mave/mave.mails/Inbox
#	find . -type f -name "*.eml" | sudo -u apache estcmd gather -cl -fm -cm casket - > /dev/null
#	estcmd search -vh -max 3 casket 'Linux'
#
#	cd /var/www/html
#	ln -v -s /var/lib/pv/mave/mave.mails .
#	cat estseek.conf.org \
#		| sed 's/^\(indexname:\).*/\1 \/var\/lib\/pv\/mave\/mave.mails\/Inbox\/casket/' \
#		| sed 's/^\(replace:\).*^file.*/\1 ^file:\/\/\/var\/lib\/pv\/mave\/{{!}}\//' \
#		> estseek.conf
#	diff -C 2 estseek.conf.org estseek.conf \
#	|| echo '/var/www/html/estseek.conf changed.'
#
##__END0__startup.sh__

##__BEGIN1__crontab.index__
#
#	MAILTO=""
#
#	*/10 * * * * cd /var/www/html; sudo -u apache ./mave_fetch
#	15 * * * * cd /var/lib/pv/mave/mave.mails/Inbox; find . -type f -name "*.eml" | sudo -u apache /usr/local/bin/estcmd gather -cl -fm -cm casket -
#	20 2 * * * cd /var/lib/pv/mave/mave.mails/Inbox; sudo -u apache /usr/local/bin/estcmd purge -cl casket
#
##__END1__crontab.index__

