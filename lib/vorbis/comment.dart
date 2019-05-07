import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_dorbis/vorbis/buffer.dart';
import 'ogg.dart';

class Comment {
  static Uint8List _vorbis = ascii.encode("vorbis");
  static Uint8List _vendor = ascii.encode("Xiphophorus libVorbis I 20000508");

  static final int OV_EIMPL = -130;

  List<Uint8List> user_comments;
  List<int> comment_lengths;
  int comments;
  Uint8List vendor;

  void init() {
    user_comments = null;
    comments = 0;
    vendor = null;
  }

  void add(String comment) {
    add0(utf8.encode(comment));
  }

  void add0(Uint8List comment) {
    List<Uint8List> foo = new List(comments + 2);
    if (user_comments != null) {
      foo.setAll(0, user_comments);
    }
    user_comments = foo;

    var goo = new List<int>(comments + 2);
    if (comment_lengths != null) {
      goo.setAll(0, comment_lengths);
    }
    comment_lengths = goo;

    Uint8List bar = new Uint8List(comment.length + 1);
    bar.setAll(0, comment);
    user_comments[comments] = bar;
    comment_lengths[comments] = comment.length;
    comments++;
    user_comments[comments] = null;
  }

  void add_tag(String tag, String contents) {
    if (contents == null) contents = "";
    add(tag + "=" + contents);
  }

  static bool tagcompare(Uint8List s1, Uint8List s2, int n) {
    int c = 0;
    int u1, u2;
    while (c < n) {
      u1 = s1[c];
      u2 = s2[c];
      if ('Z'.codeUnits.first >= u1 && u1 >= 'A'.codeUnits.first)
        u1 = (u1 - 'A'.codeUnits.first + 'a'.codeUnits.first);
      if ('Z'.codeUnits.first >= u2 && u2 >= 'A'.codeUnits.first)
        u2 = u2 - 'A'.codeUnits.first + 'a'.codeUnits.first;
      if (u1 != u2) {
        return false;
      }
      c++;
    }
    return true;
  }

  String query(String tag) {
    return query1(tag, 0);
  }

  String query1(String tag, int count) {
    int foo = query0(utf8.encode(tag), count);
    if (foo == -1) return null;
    Uint8List comment = user_comments[foo];
    for (int i = 0; i < comment_lengths[foo]; i++) {
      if (comment[i] == '='.codeUnits.first) {
        return utf8.decode(Uint8List.view(
            comment.buffer, i + 1, comment_lengths[foo] - (i + 1)));
      }
    }
    return null;
  }

  int query0(Uint8List tag, int count) {
    int i = 0;
    int found = 0;
    int fulltaglen = tag.length + 1;
    Uint8List fulltag = new Uint8List(fulltaglen);
    fulltag.setAll(0, tag);
    fulltag[tag.length] = '='.codeUnits.first;

    for (i = 0; i < comments; i++) {
      if (tagcompare(user_comments[i], fulltag, fulltaglen)) {
        if (count == found) {
          return i;
        } else {
          found++;
        }
      }
    }
    return -1;
  }

  int unpack(Buffer opb) {
    int vendorlen = opb.read0(32);
    if (vendorlen < 0) {
      clear();
      return (-1);
    }
    vendor = new Uint8List(vendorlen + 1);
    opb.read(vendor, vendorlen);
    comments = opb.read0(32);
    if (comments < 0) {
      clear();
      return (-1);
    }
    user_comments = new List(comments + 1);
    comment_lengths = new List<int>(comments + 1);

    for (int i = 0; i < comments; i++) {
      int len = opb.read0(32);
      if (len < 0) {
        clear();
        return (-1);
      }
      comment_lengths[i] = len;
      user_comments[i] = new Uint8List(len + 1);
      opb.read(user_comments[i], len);
    }
    if (opb.read0(1) != 1) {
      clear();
      return (-1);
    }
    return (0);
  }

  int pack(Buffer opb) {
    // preamble
    opb.write0(0x03, 8);
    opb.write(_vorbis);

    // vendor
    opb.write0(_vendor.length, 32);
    opb.write(_vendor);

    // comments
    opb.write0(comments, 32);
    if (comments != 0) {
      for (int i = 0; i < comments; i++) {
        if (user_comments[i] != null) {
          opb.write0(comment_lengths[i], 32);
          opb.write(user_comments[i]);
        } else {
          opb.write0(0, 32);
        }
      }
    }
    opb.write0(1, 1);
    return (0);
  }

  int header_out(Packet op) {
    Buffer opb = new Buffer();
    opb.writeinit();

    if (pack(opb) != 0) return OV_EIMPL;

    op.packet_base = new Uint8List(opb.bytes());
    op.packet = 0;
    op.bytes = opb.bytes();
    op.packet_base.setAll(0, opb.buffer);
    op.b_o_s = 0;
    op.e_o_s = 0;
    op.granulepos = 0;
    return 0;
  }

  void clear() {
    for (int i = 0; i < comments; i++) user_comments[i] = null;
    user_comments = null;
    vendor = null;
  }

  String getVendor() {
    return utf8.decode(vendor);
  }

  String getComment(int i) {
    if (comments <= i) return null;
    return utf8.decode(user_comments[i]);
  }

  String toString() {
    String foo = "Vendor: " + utf8.decode(vendor);
    for (int i = 0; i < comments; i++) {
      foo = foo + "\nComment: " + utf8.decode(user_comments[i]);
    }
    foo = foo + "\n";
    return foo;
  }
}
