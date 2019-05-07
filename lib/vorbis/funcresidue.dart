import 'dart:math';
import 'package:flutter_dorbis/vorbis/buffer.dart';
import 'package:flutter_dorbis/vorbis/block.dart';
import 'info.dart';
import 'package:flutter_dorbis/vorbis/dspstate.dart';
import 'util.dart';
import 'package:flutter_dorbis/vorbis/codebook.dart';

abstract class FuncResidue{
  static List<FuncResidue> residue_P= [new Residue0(), new Residue1(),
  new Residue2()];

  void pack(Object vr, Buffer opb);

  Object unpack(Info vi, Buffer opb);

  Object look(DspState vd, InfoMode vm, Object vr);

  void free_info(Object i);

  void free_look(Object i);

  int inverse(Block vb, Object vl, List<List<double>> inn, List<int> nonzero, int ch);
}

class Residue0 extends FuncResidue {
  void pack(Object vr, Buffer opb) {
    InfoResidue0 info = vr;
    int acc = 0;
    opb.write0(info.begin, 24);
    opb.write0(info.end, 24);

    opb.write0(info.grouping - 1, 24);
    opb.write0(info.partitions - 1, 6);
    opb.write0(info.groupbook, 8);

    for (int j = 0; j < info.partitions; j++) {
      int i = info.secondstages[j];
      if (Util.ilog(i) > 3) {
        opb.write0(i, 3);
        opb.write0(1, 1);
        opb.write0(i >> 3, 5);
      } else {
        opb.write0(i, 4); /* trailing zero */
      }
      acc += Util.icount(i);
    }
    for (int j = 0; j < acc; j++) {
      opb.write0(info.booklist[j], 8);
    }
  }

  Object unpack(Info vi, Buffer opb) {
    int acc = 0;
    InfoResidue0 info = new InfoResidue0();
    info.begin = opb.read0(24);
    info.end = opb.read0(24);
    info.grouping = opb.read0(24) + 1;
    info.partitions = opb.read0(6) + 1;
    info.groupbook = opb.read0(8);

    for (int j = 0; j < info.partitions; j++) {
      int cascade = opb.read0(3);
      if (opb.read0(1) != 0) {
        cascade |= (opb.read0(5) << 3);
      }
      info.secondstages[j] = cascade;
      acc += Util.icount(cascade);
    }

    for (int j = 0; j < acc; j++) {
      info.booklist[j] = opb.read0(8);
    }

    if (info.groupbook >= vi.books) {
      free_info(info);
      return (null);
    }

    for (int j = 0; j < acc; j++) {
      if (info.booklist[j] >= vi.books) {
        free_info(info);
        return (null);
      }
    }
    return (info);
  }

  Object look(DspState vd, InfoMode vm, Object vr) {
    InfoResidue0 info = vr;
    LookResidue0 look = new LookResidue0();
    int acc = 0;
    int dim;
    int maxstage = 0;
    look.info = info;
    look.map = vm.mapping;

    look.parts = info.partitions;
    look.fullbooks = vd.fullbooks;
    look.phrasebook = vd.fullbooks[info.groupbook];

    dim = look.phrasebook.dim;

    look.partbooks = new List(look.parts);

    for (int j = 0; j < look.parts; j++) {
      int i = info.secondstages[j];
      int stages = Util.ilog(i);
      if (stages != 0) {
        if (stages > maxstage) maxstage = stages;
        look.partbooks[j] = new List<int>(stages);
        for (int k = 0; k < stages; k++) {
          if ((i & (1 << k)) != 0) {
            look.partbooks[j][k] = info.booklist[acc++];
          }
        }
      }
    }

    look.partvals = pow(look.parts, dim).round();
    look.stages = maxstage;
    look.decodemap = new List(look.partvals);
    for (int j = 0; j < look.partvals; j++) {
      int val = j;
      int mult = look.partvals ~/ look.parts;
      look.decodemap[j] = new List<int>(dim);

      for (int k = 0; k < dim; k++) {
        int deco = val ~/ mult;
        val -= deco * mult;
        mult ~/= look.parts;
        look.decodemap[j][k] = deco;
      }
    }
    return (look);
  }

  void free_info(Object i) {}

  void free_look(Object i) {}

  static List<List<List<int>>> _01inverse_partword =
  new List(2);

  static int a1inverse(
      Block vb, Object vl, List<List<double>> inn, int ch, int decodepart) {
    int i, j, k, l, s;
    LookResidue0 look = vl;
    InfoResidue0 info = look.info;

    // move all this setup out later
    int samples_per_partition = info.grouping;
    int partitions_per_word = look.phrasebook.dim;
    int n = info.end - info.begin;

    int partvals = n ~/ samples_per_partition;
    int partwords = (partvals + partitions_per_word - 1) ~/ partitions_per_word;

    if (_01inverse_partword.length < ch) {
      _01inverse_partword = new List(ch);
    }

    for (j = 0; j < ch; j++) {
      if (_01inverse_partword[j] == null ||
          _01inverse_partword[j].length < partwords) {
        _01inverse_partword[j] = new List(partwords);
      }
    }

    for (s = 0; s < look.stages; s++) {
      i = 0;
      for (l = 0; i < partvals; l++) {
        if (s == 0) {
          for (j = 0; j < ch; j++) {
            int temp = look.phrasebook.decode(vb.opb);
            if (temp == -1) {
              return (0);
            }
            _01inverse_partword[j][l] = look.decodemap[temp];
            if (_01inverse_partword[j][l] == null) {
              return (0);
            }
          }
        }

        for (k = 0; k < partitions_per_word && i < partvals; k++, i++)
          for (j = 0; j < ch; j++) {
            int offset = info.begin + i * samples_per_partition;
            int index = _01inverse_partword[j][l][k];
            if ((info.secondstages[index] & (1 << s)) != 0) {
              CodeBook stagebook = look.fullbooks[look.partbooks[index][s]];
              if (stagebook != null) {
                if (decodepart == 0) {
                  if (stagebook.decodevs_add(
                      inn[j], offset, vb.opb, samples_per_partition) ==
                      -1) {
                    return (0);
                  }
                } else if (decodepart == 1) {
                  if (stagebook.decodev_add(
                      inn[j], offset, vb.opb, samples_per_partition) ==
                      -1) {
                    return (0);
                  }
                }
              }
            }
          }
      }
    }
    return (0);
  }

  static List<List<int>> _2inverse_partword = null;

  static int a2inverse(Block vb, Object vl, List<List<double>> inn, int ch) {
    int i, k, l, s;
    LookResidue0 look = vl;
    InfoResidue0 info = look.info;

    int samples_per_partition = info.grouping;
    int partitions_per_word = look.phrasebook.dim;
    int n = info.end - info.begin;

    int partvals = n ~/ samples_per_partition;
    int partwords = (partvals + partitions_per_word - 1) ~/ partitions_per_word;

    if (_2inverse_partword == null || _2inverse_partword.length < partwords) {
      _2inverse_partword = new List(partwords);
    }
    for (s = 0; s < look.stages; s++) {
      i = 0;
      for (l = 0; i < partvals; l++) {
        if (s == 0) {
          int temp = look.phrasebook.decode(vb.opb);
          if (temp == -1) {
            return (0);
          }
          _2inverse_partword[l] = look.decodemap[temp];
          if (_2inverse_partword[l] == null) {
            return (0);
          }
        }

        for (k = 0; k < partitions_per_word && i < partvals; k++, i++) {
          int offset = info.begin + i * samples_per_partition;
          int index = _2inverse_partword[l][k];
          if ((info.secondstages[index] & (1 << s)) != 0) {
            CodeBook stagebook = look.fullbooks[look.partbooks[index][s]];
            if (stagebook != null) {
              if (stagebook.decodevv_add(
                  inn, offset, ch, vb.opb, samples_per_partition) ==
                  -1) {
                return (0);
              }
            }
          }
        }
      }
    }
    return (0);
  }

  int inverse(
      Block vb, Object vl, List<List<double>> inn, List<int> nonzero, int ch) {
    int used = 0;
    for (int i = 0; i < ch; i++) {
      if (nonzero[i] != 0) {
        inn[used++] = inn[i];
      }
    }
    if (used != 0)
      return (a1inverse(vb, vl, inn, used, 0));
    else
      return (0);
  }
}

class LookResidue0 {
  InfoResidue0 info;
  int map;

  int parts;
  int stages;
  List<CodeBook> fullbooks;
  CodeBook phrasebook;
  List<List<int>> partbooks;

  int partvals;
  List<List<int>> decodemap;

  int postbits;
  int phrasebits;
  int frames;
}

class InfoResidue0 {
  int begin;
  int end;

  int grouping;
  int partitions;
  int groupbook;
  var secondstages = new List<int>(64);
  var booklist = new List<int>(256);

  var entmax = new List<double>(64);
  var ampmax = new List<double>(64);
  var subgrp = new List<int>(64);
  var blimit = new List<int>(64);
}

class Residue1 extends Residue0 {
  int inverse(
      Block vb, Object vl, List<List<double>> inn, List<int> nonzero, int ch) {
    int used = 0;
    for (int i = 0; i < ch; i++) {
      if (nonzero[i] != 0) {
        inn[used++] = inn[i];
      }
    }
    if (used != 0) {
      return (Residue0.a1inverse(vb, vl, inn, used, 1));
    } else {
      return 0;
    }
  }
}

class Residue2 extends Residue0 {
  int inverse(
      Block vb, Object vl, List<List<double>> inn, List<int> nonzero, int ch) {
    int i = 0;
    for (i = 0; i < ch; i++) if (nonzero[i] != 0) break;
    if (i == ch) return (0); // no nonzero vectors

    return (Residue0.a2inverse(vb, vl, inn, ch));
  }
}

