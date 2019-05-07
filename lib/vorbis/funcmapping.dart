import 'info.dart';
import 'package:flutter_dorbis/vorbis/buffer.dart';
import 'package:flutter_dorbis/vorbis/dspstate.dart';
import 'package:flutter_dorbis/vorbis/block.dart';
import 'util.dart';
import 'package:flutter_dorbis/vorbis/functime.dart';
import 'package:flutter_dorbis/vorbis/funcfloor.dart';
import 'package:flutter_dorbis/vorbis/funcresidue.dart';
import 'mdct.dart';

abstract class FuncMapping{
  static List<FuncMapping> mapping_P= [new Mapping0()];

  void pack(Info info, Object imap, Buffer buffer);

  Object unpack(Info info, Buffer buffer);

  Object look(DspState vd, InfoMode vm, Object m);

  void free_info(Object imap);

  void free_look(Object imap);

  int inverse(Block vd, Object lm);
}

class InfoMapping0{
  int submaps; // <= 16
  var chmuxlist=new List.generate(256,(_) => 0); // up to 256 channels in a Vorbis stream

  var timesubmap=new List.generate(16,(_) => 0); // [mux]
  var floorsubmap=new List.generate(16,(_) => 0); // [mux] submap to floors
  var residuesubmap=new List.generate(16,(_) => 0);// [mux] submap to residue
  var psysubmap=new List.generate(16,(_) => 0); // [mux]; encode only

  int coupling_steps;
  var coupling_mag=new List.generate(256,(_) => 0);
  var coupling_ang=new List.generate(256,(_) => 0);

  void free(){
    chmuxlist=null;
    timesubmap=null;
    floorsubmap=null;
    residuesubmap=null;
    psysubmap=null;

    coupling_mag=null;
    coupling_ang=null;
  }
}

class LookMapping0{
  InfoMode mode;
  InfoMapping0 map;
  List<Object> time_look;
  List<Object> floor_look;
  List<Object> floor_state;
  List<Object> residue_look;

  List<FuncTime> time_func;
  List<FuncFloor> floor_func;
  List<FuncResidue> residue_func;

  int ch;
  List<List<double>> decay;
  int lastframe;
}

class Mapping0 extends FuncMapping{
  static int seq=0;

  void free_info(Object imap){}

  void free_look(Object imap){}

  Object look(DspState vd, InfoMode vm, Object m){
    Info vi=vd.vi;
    LookMapping0 look=new LookMapping0();
    InfoMapping0 info=look.map=m;
    look.mode=vm;

    look.time_look=new List<Object>(info.submaps);
    look.floor_look=new List<Object>(info.submaps);
    look.residue_look=new List<Object>(info.submaps);

    look.time_func=new List<FuncTime>(info.submaps);
    look.floor_func=new List<FuncFloor>(info.submaps);
    look.residue_func=new List<FuncResidue>(info.submaps);

    for(int i=0; i<info.submaps; i++){
      int timenum=info.timesubmap[i];
      int floornum=info.floorsubmap[i];
      int resnum=info.residuesubmap[i];

      look.time_func[i]=FuncTime.time_P[vi.time_type[timenum]];
      look.time_look[i]=look.time_func[i].look(vd, vm, vi.time_param[timenum]);
      look.floor_func[i]=FuncFloor.floor_P[vi.floor_type[floornum]];
      look.floor_look[i]=look.floor_func[i].look(vd, vm,
          vi.floor_param[floornum]);
      look.residue_func[i]=FuncResidue.residue_P[vi.residue_type[resnum]];
      look.residue_look[i]=look.residue_func[i].look(vd, vm,
          vi.residue_param[resnum]);

    }

    look.ch=vi.channels;

    return (look);
  }

  void pack(Info vi, Object imap, Buffer opb){
    InfoMapping0 info=imap;

    if(info.submaps>1){
      opb.write0(1, 1);
      opb.write0(info.submaps-1, 4);
    }
    else{
      opb.write0(0, 1);
    }

    if(info.coupling_steps>0){
      opb.write0(1, 1);
      opb.write0(info.coupling_steps-1, 8);
      for(int i=0; i<info.coupling_steps; i++){
        opb.write0(info.coupling_mag[i], Util.ilog2(vi.channels));
        opb.write0(info.coupling_ang[i], Util.ilog2(vi.channels));
      }
    }
    else{
      opb.write0(0, 1);
    }

    opb.write0(0, 2); /* 2,3:reserved */

    if(info.submaps>1){
      for(int i=0; i<vi.channels; i++)
        opb.write0(info.chmuxlist[i], 4);
    }
    for(int i=0; i<info.submaps; i++){
      opb.write0(info.timesubmap[i], 8);
      opb.write0(info.floorsubmap[i], 8);
      opb.write0(info.residuesubmap[i], 8);
    }
  }

  Object unpack(Info vi, Buffer opb){
    InfoMapping0 info=new InfoMapping0();

    if(opb.read0(1)!=0){
      info.submaps=opb.read0(4)+1;
    }
    else{
      info.submaps=1;
    }

    if(opb.read0(1)!=0){
      info.coupling_steps=opb.read0(8)+1;

      for(int i=0; i<info.coupling_steps; i++){
        int testM=info.coupling_mag[i]=opb.read0(Util.ilog2(vi.channels));
        int testA=info.coupling_ang[i]=opb.read0(Util.ilog2(vi.channels));

        if(testM<0||testA<0||testM==testA||testM>=vi.channels
            ||testA>=vi.channels){
          //goto err_out;
          info.free();
          return (null);
        }
      }
    }

    if(opb.read0(2)>0){ /* 2,3:reserved */
      info.free();
      return (null);
    }

    if(info.submaps>1){
      for(int i=0; i<vi.channels; i++){
        info.chmuxlist[i]=opb.read0(4);
        if(info.chmuxlist[i]>=info.submaps){
          info.free();
          return (null);
        }
      }
    }

    for(int i=0; i<info.submaps; i++){
      info.timesubmap[i]=opb.read0(8);
      if(info.timesubmap[i]>=vi.times){
        info.free();
        return (null);
      }
      info.floorsubmap[i]=opb.read0(8);
      if(info.floorsubmap[i]>=vi.floors){
        info.free();
        return (null);
      }
      info.residuesubmap[i]=opb.read0(8);
      if(info.residuesubmap[i]>=vi.residues){
        info.free();
        return (null);
      }
    }
    return info;
  }

  List<List<double>> pcmbundle=null;
  List<int> zerobundle=null;
  List<int> nonzero=null;
  List<Object> floormemo=null;

  int inverse(Block vb, Object l){
    DspState vd=vb.vd;
    Info vi=vd.vi;
    LookMapping0 look=l;
    InfoMapping0 info=look.map;
    InfoMode mode=look.mode;
    int n=vb.pcmend=vi.blocksizes[vb.W];

    List<double> window=vd.window0[vb.W][vb.lW][vb.nW][mode.windowtype];
    if(pcmbundle==null||pcmbundle.length<vi.channels){
      pcmbundle=new List(vi.channels);
      nonzero=new List(vi.channels);
      zerobundle=new List(vi.channels);
      floormemo=new List(vi.channels);
    }

    for(int i=0; i<vi.channels; i++){
      List<double> pcm=vb.pcm[i];
      int submap=info.chmuxlist[i];

      floormemo[i]=look.floor_func[submap].inverse1(vb,
          look.floor_look[submap], floormemo[i]);
      if(floormemo[i]!=null){
        nonzero[i]=1;
      }
      else{
        nonzero[i]=0;
      }
      for(int j=0; j<n/2; j++){
        pcm[j]=0;
      }

    }

    for(int i=0; i<info.coupling_steps; i++){
      if(nonzero[info.coupling_mag[i]]!=0||nonzero[info.coupling_ang[i]]!=0){
        nonzero[info.coupling_mag[i]]=1;
        nonzero[info.coupling_ang[i]]=1;
      }
    }

    for(int i=0; i<info.submaps; i++){
      int ch_in_bundle=0;
      for(int j=0; j<vi.channels; j++){
        if(info.chmuxlist[j]==i){
          if(nonzero[j]!=0){
            zerobundle[ch_in_bundle]=1;
          }
          else{
            zerobundle[ch_in_bundle]=0;
          }
          pcmbundle[ch_in_bundle++]=vb.pcm[j];
        }
      }

      look.residue_func[i].inverse(vb, look.residue_look[i], pcmbundle,
          zerobundle, ch_in_bundle);
    }

    for(int i=info.coupling_steps-1; i>=0; i--){
      List<double> pcmM=vb.pcm[info.coupling_mag[i]];
      List<double> pcmA=vb.pcm[info.coupling_ang[i]];

      for(int j=0; j<n/2; j++){
        double mag=pcmM[j];
        double ang=pcmA[j];

        if(mag>0){
          if(ang>0){
            pcmM[j]=mag;
            pcmA[j]=mag-ang;
          }
          else{
            pcmA[j]=mag;
            pcmM[j]=mag+ang;
          }
        }
        else{
          if(ang>0){
            pcmM[j]=mag;
            pcmA[j]=mag+ang;
          }
          else{
            pcmA[j]=mag;
            pcmM[j]=mag-ang;
          }
        }
      }
    }

    for(int i=0; i<vi.channels; i++){
      List<double> pcm=vb.pcm[i];
      int submap=info.chmuxlist[i];
      look.floor_func[submap].inverse2(vb, look.floor_look[submap],
          floormemo[i], pcm);
    }

    for(int i=0; i<vi.channels; i++){
      List<double> pcm=vb.pcm[i];
      //_analysis_output("out",seq+i,pcm,n/2,0,0);
      Mdct mdct = vd.transform[vb.W][0];
      mdct.backward(pcm, pcm);
    }

    for(int i=0; i<vi.channels; i++){
      List<double> pcm=vb.pcm[i];
      if(nonzero[i]!=0){
        for(int j=0; j<n; j++){
          pcm[j]*=window[j];
        }
      }
      else{
        for(int j=0; j<n; j++){
          pcm[j]=0.0;
        }
      }
    }

    return (0);
  }
}

