# FFmpeg, cut down to what OwnTone actually decodes.
#
# nixpkgs' ffmpeg-headless is still a video encoder: x264, x265, vpx, webp,
# zimg, vidstab, vmaf and zvbi all end up in the relocated dylib closure,
# which took the bundled engine payload to 109 MB. None of it is reachable
# from an AirPlay audio path.
#
# The component list below is the one the spike arrived at empirically
# (.agents-work/20260829-owntone-macos-spike). Two entries look droppable
# and are not:
#
#   aresample / swresample  OwnTone's transcode path requires them. The
#                           first minimal build omitted both and failed.
#   mjpeg, png, scale       Cover art, not video. OwnTone decodes and
#                           rescales artwork through libav.
#   image2pipe (muxer)      Also cover art: OwnTone writes the rescaled
#                           picture back through it (src/artwork.c). Without
#                           it every artwork request answers 204 and the log
#                           says "could not find the 'image2pipe' output
#                           format". The *_pipe demuxers are the matching
#                           input side for pictures arriving in memory.
#   data (muxer)            Not a format anyone plays. OwnTone asks for it by
#                           name to get the encoder's packets back unmuxed,
#                           which is what both AirPlay paths stream
#                           (src/transcode.c, XCODE_ALAC). Without it every
#                           AirPlay device fails to start, and the only clue
#                           is "ffmpeg has no ALAC encoder" in the log.
#
# Source and version are inherited from nixpkgs' ffmpeg so there is no
# second hash to keep current: this follows whatever nixpkgs ships.
{
  lib,
  stdenv,
  ffmpeg-headless,
}:

stdenv.mkDerivation {
  pname = "ffmpeg-audio";
  inherit (ffmpeg-headless) version src;

  # ffmpeg's configure is hand-written, not autotools. It rejects the
  # per-output and --host flags the generic builder would otherwise add.
  setOutputFlags = false;
  configurePlatforms = [ ];

  configureFlags = [
    # ffmpeg's configure defaults to gcc, which on darwin fails its own
    # compiler test outright. Point it at the stdenv toolchain.
    "--cc=${stdenv.cc.targetPrefix}cc"
    "--cxx=${stdenv.cc.targetPrefix}c++"
    "--nm=${stdenv.cc.targetPrefix}nm"
    "--ar=${stdenv.cc.targetPrefix}ar"
    "--ranlib=${stdenv.cc.targetPrefix}ranlib"
    "--strip=${stdenv.cc.targetPrefix}strip"

    "--enable-shared"
    "--disable-static"
    "--disable-everything"
    "--disable-doc"
    "--disable-programs"
    "--disable-debug"
    "--disable-avdevice"
    "--enable-demuxer=ogg,flac,wav,mp3,aac,mov,image2,image2pipe,png_pipe,jpeg_pipe"
    "--enable-decoder=vorbis,flac,alac,aac,mp3,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8,mjpeg,png"
    "--enable-encoder=alac,pcm_s16le,pcm_s24le,pcm_s32le,mjpeg,png"
    "--enable-muxer=data,wav,image2,image2pipe,mp4"
    "--enable-parser=aac,flac,mpegaudio,mjpeg,png"
    "--enable-filter=abuffer,abuffersink,aformat,aresample,anull,buffer,buffersink,format,scale"
    "--enable-protocol=file,pipe,http,tcp"
  ];

  enableParallelBuilding = true;

  meta = {
    description = "FFmpeg libraries reduced to OwnTone's audio and artwork codecs";
    homepage = "https://ffmpeg.org";
    license = lib.licenses.lgpl21Plus;
    platforms = lib.platforms.darwin;
  };
}
