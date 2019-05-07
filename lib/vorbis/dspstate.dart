import 'dart:typed_data';
import 'mdct.dart';
import 'info.dart';
import 'dart:math';
import 'util.dart';
import 'package:flutter_dorbis/vorbis/codebook.dart';
import 'package:flutter_dorbis/vorbis/block.dart';
import 'package:flutter_dorbis/vorbis/funcmapping.dart';

class DspState {
  static final double M_PI = 3.1415926539;
  static final int VI_TRANSFORMB = 1;
  static final int VI_WINDOWB = 1;

  int analysisp = 0;
  Info vi;
  int modebits = 0;

  var pcm = List<List<double>>();
  int pcm_storage = 0;
  int pcm_current = 0;
  int pcm_returned = 0;

  var multipliers = List<double>();
  int envelope_storage = 0;
  int envelope_current = 0;

  int eofflag = 0;

  int lW = 0;
  int W = 0;
  int nW = 0;
  int centerW = 0;

  int granulepos = 0;
  int sequence = 0;

  int glue_bits = 0;
  int time_bits = 0;
  int floor_bits = 0;
  int res_bits = 0;

  var window0 =
      List<List<List<List<List<double>>>>>(); // block, leadin, leadout, type
  List<List<Object>> transform;
  List<CodeBook> fullbooks;
  List<Object> mode;

  Uint8List header;
  Uint8List header1;
  Uint8List header2;

  DspState() {
    transform = new List(2);
    window0 = new List(2);
    window0[0] = new List(2);
    window0[0][0] = new List(2);
    window0[0][1] = new List(2);
    window0[0][0][0] = new List(2);
    window0[0][0][1] = new List(2);
    window0[0][1][0] = new List(2);
    window0[0][1][1] = new List(2);
    window0[1] = new List(2);
    window0[1][0] = new List(2);
    window0[1][1] = new List(2);
    window0[1][0][0] = new List(2);
    window0[1][0][1] = new List(2);
    window0[1][1][0] = new List(2);
    window0[1][1][1] = new List(2);
  }

  static List<double> window(int type, int win, int left, int right) {
    var ret = new List.generate(win, (_) => 0.0);
    switch (type) {
      case 0:
        // The 'vorbis window' (window 0) is sin(sin(x)*sin(x)*2pi)
        {
          int leftbegin = win ~/ 4 - left ~/ 2;
          int rightbegin = win - win ~/ 4 - right ~/ 2;

          for (int i = 0; i < left; i++) {
            double x = (i + 0.5) / left * M_PI / 2.0;
            x = sin(x);
            x *= x;
            x *= M_PI / 2.0;
            x = sin(x);
            ret[i + leftbegin] = x;
          }

          for (int i = leftbegin + left; i < rightbegin; i++) {
            ret[i] = 1.0;
          }

          for (int i = 0; i < right; i++) {
            double x = ((right - i - .5) / right * M_PI / 2.0);
            x = sin(x);
            x *= x;
            x *= M_PI / 2.0;
            x = sin(x);
            ret[i + rightbegin] = x;
          }
        }
        break;
      default:
        //free(ret);
        return (null);
    }
    return (ret);
  }

  int init(Info vi, bool encp) {
    this.vi = vi;
    modebits = Util.ilog2(vi.modes);

    transform[0] = new List<Object>(VI_TRANSFORMB);
    transform[1] = new List<Object>(VI_TRANSFORMB);

    // MDCT is tranform 0

    transform[0][0] = new Mdct()..init(vi.blocksizes[0]);
    transform[1][0] = new Mdct()..init(vi.blocksizes[1]);

    window0[0][0][0] = new List(VI_WINDOWB);
    window0[0][0][1] = window0[0][0][0];
    window0[0][1][0] = window0[0][0][0];
    window0[0][1][1] = window0[0][0][0];
    window0[1][0][0] = new List(VI_WINDOWB);
    window0[1][0][1] = new List(VI_WINDOWB);
    window0[1][1][0] = new List(VI_WINDOWB);
    window0[1][1][1] = new List(VI_WINDOWB);

    for (int i = 0; i < VI_WINDOWB; i++) {
      window0[0][0][0][i] = window(
          i, vi.blocksizes[0], vi.blocksizes[0] ~/ 2, vi.blocksizes[0] ~/ 2);
      window0[1][0][0][i] = window(
          i, vi.blocksizes[1], vi.blocksizes[0] ~/ 2, vi.blocksizes[0] ~/ 2);
      window0[1][0][1][i] = window(
          i, vi.blocksizes[1], vi.blocksizes[0] ~/ 2, vi.blocksizes[1] ~/ 2);
      window0[1][1][0][i] = window(
          i, vi.blocksizes[1], vi.blocksizes[1] ~/ 2, vi.blocksizes[0] ~/ 2);
      window0[1][1][1][i] = window(
          i, vi.blocksizes[1], vi.blocksizes[1] ~/ 2, vi.blocksizes[1] ~/ 2);
    }

    fullbooks = new List<CodeBook>(vi.books);
    for (int i = 0; i < vi.books; i++) {
      fullbooks[i] = new CodeBook();
      fullbooks[i].init_decode(vi.book_param[i]);
    }

    pcm_storage = 8192;
    pcm = new List(vi.channels);
    {
      for (int i = 0; i < vi.channels; i++) {
        pcm[i] = new List.generate(pcm_storage, (_) => 0);
      }
    }

    lW = 0; // previous window size
    W = 0; // current window size

    centerW = vi.blocksizes[1] ~/ 2;

    pcm_current = centerW;

    mode = new List<Object>(vi.modes);
    for (int i = 0; i < vi.modes; i++) {
      int mapnum = vi.mode_param[i].mapping;
      int maptype = vi.map_type[mapnum];
      mode[i] = FuncMapping.mapping_P[maptype]
          .look(this, vi.mode_param[i], vi.map_param[mapnum]);
    }
    return (0);
  }

  int synthesis_init(Info vi) {
    init(vi, false);
    pcm_returned = centerW;
    centerW -= vi.blocksizes[W] ~/ 4 + vi.blocksizes[lW] ~/ 4;
    granulepos = -1;
    sequence = -1;
    return (0);
  }

  DspState0(Info vi) {
    init(vi, false);
    pcm_returned = centerW;
    centerW -= vi.blocksizes[W] ~/ 4 + vi.blocksizes[lW] ~/ 4;
    granulepos = -1;
    sequence = -1;
  }

  int synthesis_blockin(Block vb) {
    if (centerW > vi.blocksizes[1] / 2 && pcm_returned > 8192) {

      int shiftPCM = centerW - vi.blocksizes[1] ~/ 2;
      shiftPCM = (pcm_returned < shiftPCM ? pcm_returned : shiftPCM);

      pcm_current -= shiftPCM;
      centerW -= shiftPCM;
      pcm_returned -= shiftPCM;
      if (shiftPCM != 0) {
        for (int i = 0; i < vi.channels; i++) {
          pcm[i].setAll(0, pcm[i].getRange(shiftPCM, shiftPCM+pcm_current));
        }
      }
    }

    lW = W;
    W = vb.W;
    nW = -1;

    glue_bits += vb.glue_bits;
    time_bits += vb.time_bits;
    floor_bits += vb.floor_bits;
    res_bits += vb.res_bits;

    if (sequence + 1 != vb.sequence)
      granulepos = -1; // out of sequence; lose count

    sequence = vb.sequence;

    {
      int sizeW = vi.blocksizes[W];
      int _centerW = centerW + vi.blocksizes[lW] ~/ 4 + sizeW ~/ 4;
      int beginW = _centerW - sizeW ~/ 2;
      int endW = beginW + sizeW;
      int beginSl = 0;
      int endSl = 0;

      if (endW > pcm_storage) {
        // expand the storage
        pcm_storage = endW + vi.blocksizes[1];
        for (int i = 0; i < vi.channels; i++) {
          var foo = new List<double>(pcm_storage);
          foo.setAll(0, pcm[i]);
          pcm[i] = foo;
        }
      }

      // overlap/add PCM
      switch (W) {
        case 0:
          beginSl = 0;
          endSl = vi.blocksizes[0] ~/ 2;
          break;
        case 1:
          beginSl = vi.blocksizes[1] ~/ 4 - vi.blocksizes[lW] ~/ 4;
          endSl = beginSl + vi.blocksizes[lW] ~/ 2;
          break;
      }

      for (int j = 0; j < vi.channels; j++) {
        int _pcm = beginW;
        // the overlap/add section
        int i = 0;
        for (i = beginSl; i < endSl; i++) {
          pcm[j][_pcm + i] += vb.pcm[j][i];
        }
        // the remaining section
        for (; i < sizeW; i++) {
          pcm[j][_pcm + i] = vb.pcm[j][i];
        }
      }

      if (granulepos == -1) {
        granulepos = vb.granulepos;
      } else {
        granulepos += (_centerW - centerW);
        if (vb.granulepos != -1 && granulepos != vb.granulepos) {
          if (granulepos > vb.granulepos && vb.eofflag != 0) {
            _centerW -= (granulepos - vb.granulepos);
          }
          granulepos = vb.granulepos;
        }
      }

      centerW = _centerW;
      pcm_current = endW;
      if (vb.eofflag != 0) eofflag = 1;
    }
    return (0);
  }

  int synthesis_pcmout(List<List<List<double>>> _pcm, List<int> index) {
    if (pcm_returned < centerW) {
      if (_pcm != null) {
        for (int i = 0; i < vi.channels; i++) {
          index[i] = pcm_returned;
        }
        _pcm[0] = pcm;
      }
      return (centerW - pcm_returned);
    }
    return (0);
  }

  int synthesis_read(int bytes) {
    if (bytes != 0 && pcm_returned + bytes > centerW) return (-1);
    pcm_returned += bytes;
    return (0);
  }

  void clear() {}
}
