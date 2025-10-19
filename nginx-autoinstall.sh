#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2034,SC1091

if [[ $EUID -ne 0 ]]; then
	echo -e "Sorry, you need to run this as root"
	exit 1
fi

# Define versions
NGINX_VER=1.29.2
HEADERMOD_VER=0.39
BUILDROOT="/usr/local/src/nginx"
set -e
	# Cleanup
	# The directory should be deleted at the end of the script, but in case it fails
	#rm -r $BUILDROOT >>/dev/null 2>&1
	mkdir -p $BUILDROOT/modules

	# Dependencies
	dnf install -y ca-certificates wget curl autoconf unzip automake libtool tar git cmake liburing patch gcc gcc-c++ zstd golang

	if [ $(awk -F= '/^VERSION_ID/{print $2}' /etc/os-release|grep -oP "[0-9]+"|head -1) == "9" ]; then
		dnf -y install gcc-toolset-12-gcc gcc-toolset-12-gcc-c++
		source /opt/rh/gcc-toolset-12/enable
	elif [ $(awk -F= '/^VERSION_ID/{print $2}' /etc/os-release|grep -oP "[0-9]+"|head -1) == "10" ]; then
    dnf -y groupinstall 'Development Tools'
    dnf -y install pcre2-devel
	else
		dnf -y install gcc-toolset-11-gcc gcc-toolset-11-gcc-c++
		source /opt/rh/gcc-toolset-11/enable
	fi

	# Brotli
		cd $BUILDROOT/modules || exit 1
		git clone https://github.com/google/ngx_brotli
		cd ngx_brotli || exit 1
		git submodule update --init
		cd deps/brotli
		mkdir out && cd out
		cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS="-Ofast -m64 -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" -DCMAKE_CXX_FLAGS="-Ofast -m64 -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" -DCMAKE_INSTALL_PREFIX=./installed ..
		cmake --build . --config Release --target brotlienc

	# More Headers
		cd $BUILDROOT/modules || exit 1
		wget https://github.com/openresty/headers-more-nginx-module/archive/v${HEADERMOD_VER}.tar.gz
		tar xaf v${HEADERMOD_VER}.tar.gz

	# testcookie
		cd $BUILDROOT/modules || exit 1
		git clone https://github.com/dvershinin/testcookie-nginx-module.git
	# zstd
		git clone https://github.com/facebook/zstd.git
		cd $BUILDROOT/modules/zstd/lib
		make
    export ZSTD_INC=/usr/local/src/nginx/modules/zstd/lib/
    export ZSTD_LIB=/usr/local/src/nginx/modules/zstd/lib/libzstd.a
		cd $BUILDROOT/modules
		git clone https://github.com/tokers/zstd-nginx-module.git

	# Download and extract of Nginx source code
	cd /usr/local/src/nginx/ || exit 1
	wget -qO- http://nginx.org/download/nginx-${NGINX_VER}.tar.gz | tar zxf -
	cd nginx-${NGINX_VER} || exit 1

	cd /usr/local/src/nginx/nginx-${NGINX_VER} || exit 1

	# build boringssl
	cd $BUILDROOT/modules
	git clone https://boringssl.googlesource.com/boringssl
	cd boringssl
	git checkout --force --quiet 7cad421
	#grep -qxF 'SET_TARGET_PROPERTIES(crypto PROPERTIES SOVERSION 1)' crypto/CMakeLists.txt || echo -e '\nSET_TARGET_PROPERTIES(crypto PROPERTIES SOVERSION 1)' >> crypto/CMakeLists.txt
	#grep -qxF 'SET_TARGET_PROPERTIES(ssl PROPERTIES SOVERSION 1)' ssl/CMakeLists.txt || echo -e '\nSET_TARGET_PROPERTIES(ssl PROPERTIES SOVERSION 1)' >> ssl/CMakeLists.txt
	mkdir build
	cd $BUILDROOT/modules/boringssl/build
	cmake .. -DCMAKE_BUILD_TYPE=RelWithDebInfo
	make -j8
	cd $BUILDROOT/modules/boringssl
	mkdir -p .openssl/lib
	cd .openssl
	ln -s ../include include
	#cp "$BUILDROOT/modules/boringssl/build/crypto/libcrypto.a" /usr/lib/
	#cp "$BUILDROOT/modules/boringssl/build/ssl/libssl.a" /usr/lib/
  cp "$BUILDROOT/modules/boringssl/build/libcrypto.a" "$BUILDROOT/modules/boringssl/.openssl/lib/libcrypto.a"
	cp "$BUILDROOT/modules/boringssl/build/libssl.a" "$BUILDROOT/modules/boringssl/.openssl/lib/libssl.a"

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
		--with-openssl=$BUILDROOT/modules/boringssl"

	NGINX_MODULES="--with-threads \
		--with-file-aio \
		--with-http_ssl_module \
		--with-http_v2_module \
		--with-http_v3_module \
		--with-http_mp4_module \
		--with-http_auth_request_module \
		--with-http_slice_module \
		--with-http_stub_status_module \
		--with-http_realip_module \
		--with-http_sub_module \
                --add-module=/usr/local/src/nginx/modules/zstd-nginx-module \
		--add-module=/usr/local/src/nginx/modules/ngx_brotli \
		--add-module=/usr/local/src/nginx/modules/headers-more-nginx-module-${HEADERMOD_VER} \
		--add-module=/usr/local/src/nginx/modules/testcookie-nginx-module"


	#### PATCHES #####

	cd /usr/local/src/nginx/nginx-${NGINX_VER} || exit 1

	# Cloudflare's TLS Dynamic Record Resizing patch
		wget https://github.com/nginx-modules/ngx_http_tls_dyn_size/raw/refs/heads/master/nginx__dynamic_tls_records_1.29.2+.patch -O tcp-tls.patch
		patch -p1 <tcp-tls.patch

	# other
		# Dependencies for BoringSSL
		dnf install -y golang rust
		#source "$HOME/.cargo/env"

		cd /usr/local/src/nginx/nginx-${NGINX_VER} || exit 1

		#IO uring patch
		#wget https://raw.githubusercontent.com/hakasenyang/openssl-patch/master/nginx_io_uring.patch -O io_uring.patch
		#patch -p1 <io_uring.patch



	./configure $NGINX_OPTIONS $NGINX_MODULES --with-cc-opt="-I/usr/local/src/nginx/modules/boringssl/.openssl/include" --with-ld-opt="-lssl -lcrypto -lstdc++ -L/usr/local/src/nginx/modules/boringssl/build/"
	touch "$BUILDROOT/modules/boringssl/.openssl/include/openssl/ssl.h"
	make -j "$(nproc)"
	make install

	# remove debugging symbols
	strip -s /usr/sbin/nginx

	# Nginx installation from source does not add an init script for systemd and logrotate
	# Using the official systemd script and logrotate conf from nginx.org
	if [[ ! -e /usr/lib/systemd/system/nginx.service ]]; then
		cd /usr/lib/systemd/system/ || exit 1
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
