export REPO_ROOT=`pwd`
export PATH=$PATH:$REPO_ROOT/tools/bin

# There are limitations in `xcodebuild` command that disallow maccatalyst and maccatalyst-arm64
# to be used simultaneously: Doing that and we will get an error
#
#   Both ios-x86_64-maccatalyst and ios-arm64-maccatalyst represent two equivalent library definitions.
#
# To provide binary for both, `lipo` is probably needed.
# Likewise, `maccatalyst` and `macosx` cannot be used together. So unfortunately for now, one will
# needs multiple xcframeworks for x86_64-based and ARM-based Mac development computer.

# maccatalyst-arm64 macosx macosx-arm64
if [[ $(arch) == 'arm64' ]]; then
AVAILABLE_PLATFORMS=(iphoneos iphonesimulator macosx-arm64)
#AVAILABLE_PLATFORMS=(iphoneos iphonesimulator macosx macosx-arm64)
else
AVAILABLE_PLATFORMS=(iphoneos iphonesimulator macosx)
fi
LIBGIT2_VERSION=1.7.1
# Download build tools
test -d tools || wget -q https://github.com/light-tech/LLVM-On-iOS/releases/download/llvm12.0.0/tools.tar.xz
tar xzf tools.tar.xz

### Setup common environment variables to run CMake for a given platform
### Usage:      setup_variables PLATFORM
### where PLATFORM is the platform to build for and should be one of
###    iphoneos            (implicitly arm64)
###    iphonesimulator     (implicitly x86_64)
###    maccatalyst, maccatalyst-arm64
###    macosx, macosx-arm64
###
### After this function is executed, the variables
###    $PLATFORM
###    $ARCH
###    $SYSROOT
###    $CMAKE_ARGS
### providing basic/common CMake options will be set.
function setup_variables() {
	cd $REPO_ROOT
	PLATFORM=$1

	CMAKE_ARGS=(-DBUILD_SHARED_LIBS=NO \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_C_COMPILER_WORKS=ON \
		-DCMAKE_CXX_COMPILER_WORKS=ON \
		-DCMAKE_INSTALL_PREFIX=$REPO_ROOT/install/$PLATFORM)

	case $PLATFORM in
		"iphoneos")
			ARCH=arm64
			SYSROOT=`xcodebuild -version -sdk iphoneos Path`
			CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=$ARCH \
				-DCMAKE_OSX_SYSROOT=$SYSROOT);;

		"iphonesimulator")
			ARCH=$(arch)
			SYSROOT=`xcodebuild -version -sdk iphonesimulator Path`
			CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=$ARCH -DCMAKE_OSX_SYSROOT=$SYSROOT);;

		"macosx")
			ARCH=x86_64
			SYSROOT=`xcodebuild -version -sdk macosx Path`
			CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=$ARCH);;

		"macosx-arm64")
			ARCH=arm64
			SYSROOT=`xcodebuild -version -sdk macosx Path`
			CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES=$ARCH);;

		*)
			echo "Unsupported or missing platform! Must be one of" ${AVAILABLE_PLATFORMS[@]}
			exit 1;;
	esac
}

### Build libpcre for a given platform
function build_libpcre() {
	setup_variables $1

	rm -rf pcre-8.45
	git clone https://github.com/light-tech/PCRE.git pcre-8.45
	cd pcre-8.45

	rm -rf build && mkdir build && cd build
	CMAKE_ARGS+=(-DPCRE_BUILD_PCRECPP=NO \
		-DPCRE_BUILD_PCREGREP=NO \
		-DPCRE_BUILD_TESTS=NO \
		-DPCRE_SUPPORT_LIBBZ2=NO)

	cmake "${CMAKE_ARGS[@]}" .. >/dev/null 2>/dev/null

	cmake --build . --target install >/dev/null 2>/dev/null
}

### Build openssl for a given platform
function build_openssl() {
	setup_variables $1

	# It is better to remove and redownload the source since building make the source code directory dirty!
	rm -rf openssl-3.1.1
	test -f openssl-3.1.1.tar.gz || wget -q https://www.openssl.org/source/openssl-3.1.1.tar.gz
	tar xzf openssl-3.1.1.tar.gz
	cd openssl-3.1.1

	case $PLATFORM in
		"iphoneos")
			TARGET_OS=ios64-cross
			export CFLAGS="-isysroot $SYSROOT -arch $ARCH";;

		"iphonesimulator")
			TARGET_OS=iossimulator-xcrun
			export CFLAGS="-isysroot $SYSROOT";;

		"macosx"|"macosx-arm64")
			TARGET_OS=darwin64-$ARCH-cc
			export CFLAGS="-isysroot $SYSROOT";;

		*)
			echo "Unsupported or missing platform!";;
	esac

	# See https://wiki.openssl.org/index.php/Compilation_and_Installation
	./Configure --prefix=$REPO_ROOT/install/$PLATFORM \
		--openssldir=$REPO_ROOT/install/$PLATFORM \
		$TARGET_OS no-shared no-dso no-hw no-engine >/dev/null 2>/dev/null

	make >/dev/null 2>/dev/null
	make install_sw install_ssldirs >/dev/null 2>/dev/null
	export -n CFLAGS
}

### Build libssh2 for a given platform (assume openssl was built)
function build_libssh2() {
	setup_variables $1

	rm -rf libssh2-1.11.0
	test -f libssh2-1.11.0.tar.gz || wget -q https://www.libssh2.org/download/libssh2-1.11.0.tar.gz
	tar xzf libssh2-1.11.0.tar.gz
	cd libssh2-1.11.0

	rm -rf build && mkdir build && cd build

	CMAKE_ARGS+=(-DCRYPTO_BACKEND=OpenSSL \
		-DOPENSSL_ROOT_DIR=$REPO_ROOT/install/$PLATFORM \
		-DBUILD_EXAMPLES=OFF \
		-DBUILD_TESTING=OFF)

	cmake "${CMAKE_ARGS[@]}" .. # >/dev/null 2>/dev/null

	cmake --build . --target install # >/dev/null 2>/dev/null
}

### Build libgit2 for a single platform (given as the first and only argument)
### See @setup_variables for the list of available platform names
### Assume openssl and libssh2 was built
function build_libgit2() {
    setup_variables $1

    rm -rf libgit2-$LIBGIT2_VERSION
    # test -f v$LIBGIT2_VERSION.zip || wget -q https://github.com/libgit2/libgit2/archive/refs/tags/v$LIBGIT2_VERSION.zip
    # ditto -V -x -k --sequesterRsrc --rsrc v$LIBGIT2_VERSION.zip ./
		test -f v$LIBGIT2_VERSION.tar.gz || wget -q https://github.com/libgit2/libgit2/archive/refs/tags/v$LIBGIT2_VERSION.tar.gz
		tar xzf v$LIBGIT2_VERSION.tar.gz
    cd libgit2-$LIBGIT2_VERSION

    rm -rf build && mkdir build && cd build

    CMAKE_ARGS+=(-DBUILD_CLAR=NO)

    # See libgit2/cmake/FindPkgLibraries.cmake to understand how libgit2 looks for libssh2
    # Basically, setting LIBSSH2_FOUND forces SSH support and since we are building static library,
    # we only need the headers.
    CMAKE_ARGS+=(-DOPENSSL_ROOT_DIR=$REPO_ROOT/install/$PLATFORM \
        -DUSE_SSH=ON \
        # -DLIBSSH2_FOUND=YES \
        -DLIBSSH2_INCLUDE_DIRS=$REPO_ROOT/install/$PLATFORM/include \
				-DGIT_RAND_GETENTROPY=0 \
				-DGIT_SSH_MEMORY_CREDENTIALS=1 \
				-DGIT_REGEX_REGCOMP=1 \
				-DBUILD_TESTS=OFF)

    cmake "${CMAKE_ARGS[@]}" .. # >/dev/null 2>/dev/null

    cmake --build . --target install # >/dev/null 2>/dev/null
}

### Create xcframework for a given library
function build_xcframework() {
	rm -rf $FWNAME.xcframework
	local FWNAME=$1
	shift
	local PLATFORMS=( "$@" )
	local FRAMEWORKS_ARGS=()

	echo "Building" $FWNAME "XCFramework containing" ${PLATFORMS[@]}

	for p in ${PLATFORMS[@]}; do
		FRAMEWORKS_ARGS+=("-library" "install/$p/$FWNAME.a" "-headers" "install/$p/include")
	done

	cd $REPO_ROOT
	xcodebuild -create-xcframework ${FRAMEWORKS_ARGS[@]} -output $FWNAME.xcframework
}

### Copy SwiftGit2's module.modulemap to libgit2.xcframework/*/Headers
### so that we can use libgit2 C API in Swift (e.g. via SwiftGit2)
function copy_modulemap() {
    local FWDIRS=$(find Clibgit2.xcframework -mindepth 1 -maxdepth 1 -type d)
    for d in ${FWDIRS[@]}; do
        echo $d
        #mkdir -p $d/Headers/Clibgit2
        #cp Clibgit2_modulemap $d/Headers/Clibgit2/module.modulemap
        cp Clibgit2_modulemap $d/Headers/module.modulemap
    done
}

# function copy_opensslHeader() {
#     local FWDIRS=$(find Clibgit2.xcframework -mindepth 1 -maxdepth 1 -type d)
#     for d in ${FWDIRS[@]}; do
#         echo $d
#         mkdir -p $d/Headers/Clibgit2
#         cp OpenSSL.h $d/Headers/Clibgit2/OpenSSL.h
#     done
# }

rm -rf install

### Build libgit2 and Clibgit2 frameworks for all available platforms

for p in ${AVAILABLE_PLATFORMS[@]}; do
	echo "Build libraries for $p"
	build_libpcre $p
	build_openssl $p
	build_libssh2 $p
	build_libgit2 $p

	# Merge all static libs as libgit2.a since xcodebuild doesn't allow specifying multiple .a
	cd $REPO_ROOT/install/$p
	libtool -static -o libgit2.a lib/*.a
done

# lipo -create install/maccatalyst/libgit2.a install/maccatalyst-arm64/libgit2.a -output install/maccatalyst/libgit2.a
# lipo -create install/macosx/libgit2.a install/macosx-arm64/libgit2.a -output install/macosx/libgit2.a
# Build raw libgit2 XCFramework for Objective-C usage
build_xcframework libgit2 ${AVAILABLE_PLATFORMS[@]}
# rm -rf libgit2.xcframework.zip
# zip -r libgit2.xcframework.zip libgit2.xcframework/

# Build Clibgit2 XCFramework for use with SwiftGit2
rm -rf Clibgit2.xcframework
mv libgit2.xcframework Clibgit2.xcframework
copy_modulemap

zip -r Clibgit2.xcframework.zip Clibgit2.xcframework/
