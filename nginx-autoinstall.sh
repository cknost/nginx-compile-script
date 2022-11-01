#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2034,SC1091

if [[ $EUID -ne 0 ]]; then
	echo -e "Sorry, you need to run this as root"
	exit 1
fi

# Define versions
NGINX_VER=1.23.1
HEADERMOD_VER=0.34

	# Cleanup
	# The directory should be deleted at the end of the script, but in case it fails
	rm -r /usr/local/src/nginx/ >>/dev/null 2>&1
	mkdir -p /usr/local/src/nginx/modules

	# Dependencies
	#dnf install -y build-essential ca-certificates wget curl libpcre3 libpcre3-dev autoconf unzip automake libtool tar git libssl-dev zlib1g-dev uuid-dev libxml2-dev libxslt1-dev cmake liburing liburing-devel


	#Brotli
		cd /usr/local/src/nginx/modules || exit 1
		git clone https://github.com/google/ngx_brotli
		cd ngx_brotli || exit 1
		git submodule update --init

	# More Headers
		cd /usr/local/src/nginx/modules || exit 1
		wget https://github.com/openresty/headers-more-nginx-module/archive/v${HEADERMOD_VER}.tar.gz
		tar xaf v${HEADERMOD_VER}.tar.gz


	# Download and extract of Nginx source code
	cd /usr/local/src/nginx/ || exit 1
	wget -qO- http://nginx.org/download/nginx-${NGINX_VER}.tar.gz | tar zxf -
	cd nginx-${NGINX_VER} || exit 1

	# As the default nginx.conf does not work, we download a clean and working conf from my GitHub.
	# We do it only if it does not already exist, so that it is not overriten if Nginx is being updated
	if [[ ! -e /etc/nginx/nginx.conf ]]; then
		mkdir -p /etc/nginx
		cd /etc/nginx || exit 1
		wget https://raw.githubusercontent.com/Angristan/nginx-autoinstall/master/conf/nginx.conf
	fi
	cd /usr/local/src/nginx/nginx-${NGINX_VER} || exit 1

	NGINX_OPTIONS="
		--prefix=/etc/nginx \
		--sbin-path=/usr/sbin/nginx \
		--conf-path=/etc/nginx/nginx.conf \
		--error-log-path=/var/log/nginx/error.log \
		--http-log-path=/var/log/nginx/access.log \
		--pid-path=/var/run/nginx.pid \
		--lock-path=/var/run/nginx.lock \
		--http-client-body-temp-path=/var/cache/nginx/client_temp \
		--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
		--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
		--user=nginx \
		--group=nginx \
		--with-cc-opt=-Wno-deprecated-declarations \
		--with-cc-opt=-Wno-ignored-qualifiers"

	NGINX_MODULES="--with-threads \
		--with-file-aio \
		--with-http_ssl_module \
		--with-http_v2_module \
		--with-http_mp4_module \
		--with-http_auth_request_module \
		--with-http_slice_module \
		--with-http_stub_status_module \
		--with-http_realip_module \
		--with-http_sub_module"


		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo "--add-module=/usr/local/src/nginx/modules/ngx_brotli"
		)

		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo "--add-module=/usr/local/src/nginx/modules/headers-more-nginx-module-${HEADERMOD_VER}"
		)

	# Cloudflare's TLS Dynamic Record Resizing patch
		wget https://raw.githubusercontent.com/nginx-modules/ngx_http_tls_dyn_size/master/nginx__dynamic_tls_records_1.17.7%2B.patch -O tcp-tls.patch
		patch -p1 <tcp-tls.patch

	# HTTP3
		cd /usr/local/src/nginx/modules || exit 1
		git clone --depth 1 --recursive https://github.com/cloudflare/quiche
		# Dependencies for BoringSSL and Quiche
		dnf install -y golang
		# Rust is not packaged so that's the only way...
		curl -sSf https://sh.rustup.rs | sh -s -- -y
		source "$HOME/.cargo/env"

		cd /usr/local/src/nginx/nginx-${NGINX_VER} || exit 1
		# Patch BoringSSL OCSP stapling
		wget https://raw.githubusercontent.com/kn007/patch/35f2b0decbc510f2c8adab9261e3d46ba1398e33/Enable_BoringSSL_OCSP.patch -O Enable_BoringSSL_OCSP.patch
		patch -p01<Enable_BoringSSL_OCSP.patch
		# Apply actual patch
		patch -p01 </usr/local/src/nginx/modules/quiche/nginx/nginx-1.16.patch

		# Apply patch for nginx > 1.19.7 (source: https://github.com/cloudflare/quiche/issues/936#issuecomment-857618081)
		wget https://raw.githubusercontent.com/angristan/nginx-autoinstall/master/patches/nginx-http3-1.19.7.patch -O nginx-http3.patch
		patch -p01 <nginx-http3.patch

		NGINX_OPTIONS=$(
			echo "$NGINX_OPTIONS"
			echo --with-openssl=/usr/local/src/nginx/modules/quiche/quiche/deps/boringssl --with-quiche=/usr/local/src/nginx/modules/quiche
		)
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --with-http_v3_module
		)

		#IO uring patch
		wget https://raw.githubusercontent.com/hakasenyang/openssl-patch/master/nginx_io_uring.patch -O io_uring.patch
		patch -p1 <io_uring.patch

	# Cloudflare's Cloudflare's full HPACK encoding patch
			wget https://raw.githubusercontent.com/angristan/nginx-autoinstall/master/patches/nginx_hpack_push_with_http3.patch -O nginx_http2_hpack.patch
		patch -p1 <nginx_http2_hpack.patch

		NGINX_OPTIONS=$(
			echo "$NGINX_OPTIONS"
			echo --with-http_v2_hpack_enc
		)

	./configure $NGINX_OPTIONS $NGINX_MODULES
	make -j "$(nproc)"
	make install

	# remove debugging symbols
	strip -s /usr/sbin/nginx

	# Nginx installation from source does not add an init script for systemd and logrotate
	# Using the official systemd script and logrotate conf from nginx.org
	if [[ ! -e /lib/systemd/system/nginx.service ]]; then
		cd /lib/systemd/system/ || exit 1
		wget https://raw.githubusercontent.com/Angristan/nginx-autoinstall/master/conf/nginx.service
		# Enable nginx start at boot
		systemctl enable nginx
	fi

	if [[ ! -e /etc/logrotate.d/nginx ]]; then
		cd /etc/logrotate.d/ || exit 1
		wget https://raw.githubusercontent.com/Angristan/nginx-autoinstall/master/conf/nginx-logrotate -O nginx
	fi

	# Nginx's cache directory is not created by default
	if [[ ! -d /var/cache/nginx ]]; then
		mkdir -p /var/cache/nginx
	fi

	# We add the sites-* folders as some use them.
	if [[ ! -d /etc/nginx/sites-available ]]; then
		mkdir -p /etc/nginx/sites-available
	fi
	if [[ ! -d /etc/nginx/sites-enabled ]]; then
		mkdir -p /etc/nginx/sites-enabled
	fi
	if [[ ! -d /etc/nginx/conf.d ]]; then
		mkdir -p /etc/nginx/conf.d
	fi

	# Restart Nginx
	systemctl restart nginx

	# Removing temporary Nginx and modules files
#	rm -r /usr/local/src/nginx

	# We're done !
	echo "Installation done."
