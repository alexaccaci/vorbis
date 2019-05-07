import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_dorbis/vorbis/ogg.dart';
import 'package:flutter_dorbis/vorbis/info.dart';
import 'package:flutter_dorbis/vorbis/comment.dart';
import 'package:flutter_dorbis/vorbis/dspstate.dart';
import 'package:flutter_dorbis/vorbis/block.dart';
import 'package:flutter_dorbis/vorbis/wavheader.dart';

class Decoder {

  int _getSamples(Uint8List data)
  {
    int retval = 0;
    SyncState oy = new SyncState();
    StreamState os = new StreamState();
    Page og = new Page(); // Ogg bitstream
    int readed = 0;
    int bytes = 0;

    while (true) {
      int eos = 0;
      bytes = _readOgg(oy, data, readed);
      readed += bytes;

      if (oy.pageout(og) != 1) {
        if (bytes < 4096) break;
        print("Input does not appear to be an Ogg bitstream.");
        return -1;
      }
      os.init(og.serialno());
      if (os.pagein(og) < 0) {
        print("Error reading first page of Ogg bitstream data.");
        return -2;
      }

      while (eos == 0) {
        while (eos == 0) {
          int result = oy.pageout(og);
          if (result == 0) break; // need more data
          if (result == -1) {
            print("Corrupt or missing data in bitstream; continuing...");
          } else {
            retval = og.granulepos();
            //print("granulepos $retval");
            os.pagein(og);
            if (og.eos() != 0) eos = 1;
          }
        }
        if (eos == 0) {
          bytes = _readOgg(oy, data, readed);
          readed += bytes;
          if (bytes <= 0) eos = 1;
        }
      }
      os.clear();
    }
    // OK, clean up the framer
    oy.clear();
    return retval;
  }

  int _readOgg(SyncState oy, Uint8List data, int readed) {
    int bytes = 0;
    int toRead = data.length - readed;
    int index = oy.buffer(4096);
    if (toRead > 0) {
      if(toRead > 4096)
        bytes = 4096;
      else
        bytes = toRead;
      oy.data.setAll(index, Uint8List.view(data.buffer, readed, bytes));
      //print(oy.data);
      oy.wrote(bytes);
    }
    else
      oy.wrote(-1);
    return bytes;
  }


  void decode(Uint8List data, File dst)
  {
    print("Start decoder");
    int nsamples = _getSamples(data);

    int convsize = 4096 * 2;
    Uint8List convbuffer = new Uint8List(convsize);

    SyncState oy = new SyncState();
    StreamState os = new StreamState();
    Page og = new Page(); // Ogg bitstream
    Packet op = new Packet();

    Info vi = new Info();
    Comment vc = new Comment();
    DspState vd = new DspState();
    Block vb = new Block(vd);

    int readed = 0;
    int bytes = 0;
    int written = 0;
    int packet = 0;

    // Decode setup
    while (true) {
      int eos = 0;

      bytes = _readOgg(oy, data, readed);
      readed += bytes;

      if (oy.pageout(og) != 1) {
        if (bytes < 4096) break;
        print("Input does not appear to be an Ogg bitstream.");
        return;
      }

      os.init(og.serialno());
      vi.init();
      vc.init();
      if (os.pagein(og) < 0) {
        print("Error reading first page of Ogg bitstream data.");
        return;
      }

      if (os.packetout(op) != 1) {
        print("Error reading initial header packet.");
        return;
      }

      if (vi.synthesis_headerin(vc, op) < 0) {
        print("This Ogg bitstream does not contain Vorbis audio data.");
        return;
      }

      int i = 0;
      while (i < 2) {
        while (i < 2) {
          int result = oy.pageout(og);
          if (result == 0) break; // Need more data
          if (result == 1) {
            os.pagein(og);
            while (i < 2) {
              result = os.packetout(op);
              if (result == 0) break;
              if (result == -1) {
                print("Corrupt secondary header.  Exiting.");
              }
              vi.synthesis_headerin(vc, op);
              i++;
            }
          }
        }
        bytes = _readOgg(oy, data, readed);
        readed += bytes;
        if (bytes == 0 && i < 2) {
          print("End of file before finding all Vorbis headers!");
        }
      }

      List<Uint8List> ptr = vc.user_comments;
      for (int j = 0; j < ptr.length; j++) {
        if (ptr[j] == null) break;
        print(ptr[j]);
      }
      print("\nBitstream is ${vi.channels} channel, ${vi.rate} Hz");
      var vendor = utf8.decode(vc.vendor);
      print("Encoded by: $vendor\n");

      Uint8List header = WavHeader.getWavHeader(2*nsamples*vi.channels+WAVHEADERLEN,vi.channels,vi.rate,16);
      dst.writeAsBytesSync(header, mode: FileMode.append);

      convsize = 4096 ~/ vi.channels;

      vd.synthesis_init(vi);
      vb.init(vd);

      List<List<List<double>>> _pcm = new List(1);
      List<int> _index = new List.generate(vi.channels,(_) => 0);
      while (eos == 0) {
        while (eos == 0) {
          int result = oy.pageout(og);
          if (result == 0) break; // need more data
          if (result == -1) {
            print("Corrupt or missing data in bitstream; continuing...");
          } else {
            os.pagein(og);
            while (true) {
              result = os.packetout(op);
              if (result == 0) break; // need more data
              if (result == -1) {
                // already complained above
              } else {
                int samples;
                if (vb.synthesis(op) == 0) {
                  vd.synthesis_blockin(vb);
                }

                while ((samples = vd.synthesis_pcmout(_pcm, _index)) > 0) {
                  packet++;

                  List<List<double>> pcm = _pcm[0];
                  int bout = (samples < convsize ? samples : convsize);

                  // convert floats to signed 16 bit little endian
                  for (i = 0; i < vi.channels; i++) {
                    int ptr = i * 2;
                    int mono = _index[i];
                    for (int j = 0; j < bout; j++) {
                      int val = (pcm[i][mono + j] * 32767.0).round();
                      if (val > 32767)
                        val = 32767;
                      if (val < -32768)
                        val = -32768;
                      if (val < 0)
                        val = val|0x8000;
                      convbuffer[ptr] = (val);
                      convbuffer[ptr + 1] = (val >> 8);
                      ptr += 2*vi.channels;
                    }
                  }
                  written+=2*vi.channels*bout;
                  print("granulepos "+og.granulepos().toString()+ " written $written");
                  dst.writeAsBytesSync(Uint8List.view(convbuffer.buffer,0, 2*vi.channels*bout), mode: FileMode.append, flush: true);

                  vd.synthesis_read(bout);
                }
              }
            }
            if (og.eos() != 0) eos = 1;
          }
        }
        if (eos == 0) {
          bytes = _readOgg(oy, data, readed);
          readed += bytes;
          if (bytes <= 0) eos = 1;
        }
      }

      os.clear();

      vb.clear();
      vd.clear();
      vi.clear(); // must be called last
    }

    // OK, clean up the framer
    oy.clear();
    print("Done decoder $written.");
  }

}