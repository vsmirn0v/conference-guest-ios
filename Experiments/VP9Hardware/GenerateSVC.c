#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "vpx/vpx_encoder.h"
#include "vpx/vp8cx.h"
#define OK(x) do {if ((x)!=VPX_CODEC_OK) {fprintf(stderr,"Failed %s: %s\n",#x,vpx_codec_error(&ctx)); exit(1);}} while(0)
int main(int argc,char **argv) {
 if(argc!=2) {fprintf(stderr,"Usage: generate-svc output.bin\n");return 2;}
 vpx_codec_ctx_t ctx={0}; vpx_codec_enc_cfg_t cfg;
 OK(vpx_codec_enc_config_default(vpx_codec_vp9_cx(), &cfg,0));
 cfg.g_w=640; cfg.g_h=360; cfg.g_timebase.num=1; cfg.g_timebase.den=10;
 cfg.g_threads=2; cfg.g_lag_in_frames=0; cfg.g_error_resilient=VPX_ERROR_RESILIENT_DEFAULT;
 cfg.rc_end_usage=VPX_CBR; cfg.rc_target_bitrate=1000; cfg.rc_min_quantizer=20; cfg.rc_max_quantizer=30;
 cfg.ss_number_layers=3; cfg.ss_target_bitrate[0]=150;cfg.ss_target_bitrate[1]=350;cfg.ss_target_bitrate[2]=1000;
 cfg.layer_target_bitrate[0]=150; cfg.layer_target_bitrate[1]=350; cfg.layer_target_bitrate[2]=1000; cfg.ts_number_layers=1; cfg.ts_rate_decimator[0]=1; cfg.ts_target_bitrate[0]=1000;
 OK(vpx_codec_enc_init(&ctx,vpx_codec_vp9_cx(), &cfg,0));
 OK(vpx_codec_control(&ctx,VP8E_SET_CPUUSED,8)); OK(vpx_codec_control(&ctx,VP9E_SET_SVC,1));
 vpx_svc_extra_cfg_t svc={0};
 for(int i=0;i<3;i++){svc.scaling_factor_num[i]=1;svc.scaling_factor_den[i]=1<<(2-i);svc.max_quantizers[i]=30;svc.min_quantizers[i]=20;}
 OK(vpx_codec_control(&ctx,VP9E_SET_SVC_PARAMETERS,&svc));
 OK(vpx_codec_control(&ctx,VP9E_SET_SVC_INTER_LAYER_PRED,2));
 vpx_image_t raw; if(!vpx_img_alloc(&raw,VPX_IMG_FMT_I420,640,360,1))return 1;
 FILE *out=fopen(argv[1],"wb"); if(!out){perror("output");return 2;}
 for(int n=0;n<12;n++){
  for(int y=0;y<360;y++)for(int x=0;x<640;x++)raw.planes[0][y*raw.stride[0]+x]=(x+y+n*9)%220+16;
  for(int c=1;c<3;c++)for(int y=0;y<180;y++)for(int x=0;x<320;x++)raw.planes[c][y*raw.stride[c]+x]=(x+y+n*4)%200+28;
  OK(vpx_codec_encode(&ctx,&raw,n,1,n==0?VPX_EFLAG_FORCE_KF:0,VPX_DL_REALTIME));
  vpx_codec_iter_t it=NULL;const vpx_codec_cx_pkt_t *pkt;
  while((pkt=vpx_codec_get_cx_data(&ctx,&it))) if(pkt->kind==VPX_CODEC_CX_FRAME_PKT){uint32_t size=(uint32_t)pkt->data.frame.sz;fwrite(&size,4,1,out);fwrite(pkt->data.frame.buf,1,size,out);printf("FRAME %d %u %d\n",n,size,!!(pkt->data.frame.flags&VPX_FRAME_IS_KEY));}
 }
 fclose(out);vpx_img_free(&raw);vpx_codec_destroy(&ctx);return 0;
}
