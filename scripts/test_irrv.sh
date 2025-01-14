#!/bin/bash

function Usage()
{

    cat << EOF
test_irrv.sh /path/to/aic/workdir streaming:latest icr:latest Profile.yml GameResolution
              [-t test-set] [-s SrcWidthxSrcHeight] [-q quality] [-b target-bitrate] [-mb max-bitrate]
              [-f googletest-filter]

The first five arguments are mandatory:
-- Profile.yml is expected to be in /path/to/aic/workdir
-- GameResolution is specified as WidthxHeight (e.g. 1920x1080). This is the resolution that the game
   and encoder (with alignment adjustments) are expected to initialize with.

Optional Args:
* -t  | --test-set : Test set to use. Any input outside supported set will use default.
                     Supported options: "all" (default), "basic".
  -s  | --src-res  : Specify resolution of test source content in WxH format (e.g.1280x720).
                     This should be >= Game resolution. Default value = Game Resolution. 
                     If test allows resolution change, this should be >= Maximum of all resolutions in test
* -q  | --quality  : TU Setting for Encoder. Any input outside supported set will use default
                     Supported options: 1,4,7. Default Value = 4 (TU4)
* -b  | --target-bitrate : Target bitrate to use in test (e.g. 3.2M). Default value = 3.3M
* -mb | --max-bitrate    : Max bitrate to use in test (e.g. 5.4M). Default value = 6.6M
* -f  | --gtest_filter   : Custom googletest filter setting. Onus on caller to issue a valid setting
EOF
}

function parse_optional_args()
{
    while (("$#"))
    do
        case "$1" in
            -t | --test-set )
                TEST_SET=$2
                shift 2
                ;;
            -s | --src-res )
                SRC_RESOLUTION=$2
                shift 2
                ;;
            -q | --quality )
                QUALITY=$2
                [$2 -ne 1] && [$2 -ne 4] && [$2 -ne 7] && QUALITY=4
                shift 2
                ;;
            -b | --target-bitrate )
                TARGET_BITRATE=$2
                shift 2
                ;;
            -mb | --max-bitrate )
                MAX_BITRATE=$2
                shift 2
                ;;
            -f  | --gtest_filter )
                GTEST_SETTINGS="--gtest_filter=$2"
                shift 2
                ;;
            *)
                echo "Unknown argument: $1"
                shift
                ;;
        esac
    done
}

function get_framerate() {
  echo "$1" | sed -E 's/.*fr ([0-9\.]*).*/\1/'
}

function is_av1_test() {
  if echo $1 | grep -q av1; then
    return 0
  fi
  return 1
}

function check_av1() {
  if $VAINFO_DOCKER vainfo --display drm --device $DEVICE 2>/dev/null | grep VAEntrypointEncSliceLP | grep -q VAProfileAV1; then
    return 0
  fi
  return 1
}

SCRIPT_PATH=$(dirname $(which $0))

[ $# -lt 5 ] && Usage && exit

#Mandatory Args
AIC_WORKDIR=$(realpath $1)
ESC=$2
ICR=$3
PROFILE=$4
GAME_RESOLUTION=$5

#Optional args
TEST_SET=all
SRC_RESOLUTION=$GAME_RESOLUTION
QUALITY=4
TARGET_BITRATE=3.3M
MAX_BITRATE=6.6M
GTEST_SETTINGS="--gtest_filter=*"

shift 5
parse_optional_args $@

set -x

res=0

DEVICE=${DEVICE:-/dev/dri/renderD128}
DEVICE_GRP=$(stat --format %g $DEVICE)

# helper docker to generate content to use as input to aic-emu
FFMPEG_DOCKER="docker run --rm -u $(id -u):$(id -g) \
  -e DEVICE=$DEVICE --device $DEVICE --group-add $DEVICE_GRP \
  -v $AIC_WORKDIR:/opt/workdir \
  --name ffmpeg \
  $ICR"

AIC_DOCKER="docker create -u $(id -u):$(id -g) \
  -e DEVICE=$DEVICE --device $DEVICE --group-add $DEVICE_GRP \
  --network host -v $AIC_WORKDIR:/opt/workdir \
  --name emu0 \
  $ICR \
    aic-emu --cmd /opt/workdir/$PROFILE \
      --content /opt/workdir/test.bgra \
      --hwc-sock /opt/workdir/hwc-sock \
      --device $DEVICE"

ESC_DOCKER="docker run --rm \
  -e DEVICE=$DEVICE --device $DEVICE --group-add $DEVICE_GRP \
  --network host \
  --name esc0 \
  $ESC"

ICR_DOCKER="docker create -u $(id -u):$(id -g) \
  -e DEVICE=$DEVICE -e VAAPI_DEVICE=$DEVICE --device $DEVICE --group-add $DEVICE_GRP \
  --network host -v $AIC_WORKDIR:/opt/workdir \
  -e render_server_port=23432 \
  --name icr0 \
  $ICR"

VAINFO_DOCKER="docker run --rm \
  -e DEVICE=$DEVICE --device $DEVICE --group-add $DEVICE_GRP \
  --name vainfo0 \
  $ICR"

ffmpeg_cmd="ffmpeg -f lavfi -i testsrc=size=${SRC_RESOLUTION}:rate=30 -pix_fmt bgra -frames:v 150 -f rawvideo -y /opt/workdir/test.bgra"

icr_cases_all=(
  # h264
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 30 -url irrv:264 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 0 -hwc_sock /opt/workdir/hwc-sock"
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 30 -url irrv:264 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 1 -hwc_sock /opt/workdir/hwc-sock"
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 60 -url irrv:264 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 0 -hwc_sock /opt/workdir/hwc-sock"
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 60 -url irrv:264 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 1 -hwc_sock /opt/workdir/hwc-sock"
  # h265
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 30 -url irrv:265 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 0 -hwc_sock /opt/workdir/hwc-sock"
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 30 -url irrv:265 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 1 -hwc_sock /opt/workdir/hwc-sock"
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 60 -url irrv:265 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 0 -hwc_sock /opt/workdir/hwc-sock"
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 60 -url irrv:265 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 1 -hwc_sock /opt/workdir/hwc-sock"
  # av1
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 30 -url irrv:av1 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 0 -hwc_sock /opt/workdir/hwc-sock"
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 30 -url irrv:av1 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 1 -hwc_sock /opt/workdir/hwc-sock"
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 60 -url irrv:av1 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 0 -hwc_sock /opt/workdir/hwc-sock"
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 60 -url irrv:av1 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 1 -hwc_sock /opt/workdir/hwc-sock"
)

icr_cases_basic=(
  # Basic set covering Codec, FrameRate and TCAE settings
  # h264
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 30 -url irrv:264 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 1 -hwc_sock /opt/workdir/hwc-sock"
  # h265
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 60 -url irrv:265 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 0 -hwc_sock /opt/workdir/hwc-sock"
  # av1
  "icr_encoder 0 -streaming -res ${GAME_RESOLUTION} -fr 30 -url irrv:av1 -plugin qsv -lowpower -quality ${QUALITY} -ratectrl VBR -b ${TARGET_BITRATE} -maxrate ${MAX_BITRATE} -tcae 0 -hwc_sock /opt/workdir/hwc-sock"
)


$FFMPEG_DOCKER $ffmpeg_cmd

icr_cases=("${icr_cases_all[@]}")
if [ "${TEST_SET}" == "basic" ]
then
    icr_cases=("${icr_cases_basic[@]}")
fi

count=0
success=0
skipped=0

for c in "${icr_cases[@]}"; do
  echo ">>> Testing with:"
  echo "$c"
  echo "<<<"

  fail=0

  if is_av1_test "$c" && ! check_av1; then
    echo "Skipping test since av1 encoding is not supported"
    skipped=$((++skipped))
    continue
  fi

  if ! $AIC_DOCKER; then
    fail=1
  fi
  if ! $ICR_DOCKER $c; then
    fail=1
  fi
  docker start emu0
  docker start icr0
  if ! $ESC_DOCKER irrv-client-test --framerate $(get_framerate "$c") ${GTEST_SETTINGS}; then
    fail=1
  fi
  docker logs icr0 > $AIC_WORKDIR/logs_$count.${PROFILE%.*}.icr0.txt 2>&1
  docker logs emu0 > $AIC_WORKDIR/logs_$count.${PROFILE%.*}.emu0.txt 2>&1
  docker stop icr0 emu0
  docker rm icr0 emu0

  if [[ $fail -eq 0 ]]; then
      success=$((++success))
  else
      res=1
  fi

  count=$((++count))
done

echo "${PROFILE}: ${success} tests passed (${count} run, ${skipped} skipped)"

exit $res

