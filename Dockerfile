FROM fedora
#FROM fedora:28

LABEL 'maintainer=Furutanian <furutanian@gmail.com>'

ARG http_proxy
ARG https_proxy

RUN set -x \
	&& dnf install -y \
		httpd \
		ruby \
		sudo \
		qdbm \
		ruby-qdbm \
		hyperestraier \
		findutils \
		git \
		procps-ng \
		net-tools \
	&& rm -rf /var/cache/dnf/* \
	&& dnf clean all

# git clone mave しておくこと
COPY mave /var/www/cgi-bin
RUN cat /var/www/cgi-bin/dot.htaccess \
		| sed 's/\(Action.*rhtml-script\)\(.*maverick\)/\1 \/cgi-bin/' \
		> /var/www/cgi-bin/.htaccess \
	&& mkdir -p /var/lib/mave/conf \
	&& mkdir -p /var/lib/mave/mave.mails

RUN mv /etc/httpd/conf/httpd.conf /etc/httpd/conf/httpd.conf.org \
	&& cat /etc/httpd/conf/httpd.conf.org \
		| sed '/^<Directory "\/var\/www\/cgi-bin">/,/^</s/AllowOverride None/AllowOverride All/' \
		| sed '/^<Directory "\/var\/www\/cgi-bin">/,/^</s/Options None/Options All/' \
		> /etc/httpd/conf/httpd.conf \
	&& diff -C 2 /etc/httpd/conf/httpd.conf.org /etc/httpd/conf/httpd.conf \
	|| echo '/etc/httpd/conf/httpd.conf changed.'
RUN systemctl enable httpd

EXPOSE 80

# Dockerfile 中の設定スクリプトを抽出するスクリプトを出力、実行
COPY Dockerfile .
RUN echo $'\
cat Dockerfile | sed -n \'/^##__BEGIN0/,/^##__END0/p\' | sed \'s/^#//\' > startup.sh\n\
cat Dockerfile | sed -n \'/^##__BEGIN1/,/^##__END1/p\' | sed \'s/^#//\' > pop.sh\n\
' > extract.sh && bash extract.sh

# docker-compose up の最後に実行される設定スクリプト
##__BEGIN0__startup.sh__
#
#	chown -v apache:apache /var/lib/mave/mave.mails
#	if [ ! -e /var/lib/mave/conf/mave.config ]; then
#		cat /var/www/cgi-bin/mave.config.sample \
#			| sed 's!\(^@configs\[:ROOT_DIRECTORY\].*= \).*!\1"/var/lib/mave/mave.mails"!' \
#			> /var/lib/mave/conf/mave.config
#		diff -C 2 /var/www/cgi-bin/mave.config.sample /var/lib/mave/conf/mave.config
#	fi
#	ln -v -s /var/lib/mave/conf/mave.config /var/www/cgi-bin
#
#	bash pop.sh &
#
##__END0__startup.sh__

##__BEGIN1__pop.sh__
#
#	cd /var/www/cgi-bin
#	while true
#	do
#		date
#		sudo -u apache ./mave_fetch
#		sleep 60
#	done
#
##__END1__pop.sh__

