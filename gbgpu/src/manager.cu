/*  This code was created by Michael Katz.
 *  It is shared under the GNU license (see below).
 *  This is the central piece of code. This file implements a class
 *  that takes data in on the cpu side, copies
 *  it to the gpu, and exposes functions that let
 *  you perform actions with the GPU.
 *
 *  This class will get translated into python via cython.
 *
 *
 *
 *  Copyright (C) 2019 Michael Katz
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with with program; see the file COPYING. If not, write to the
 *  Free Software Foundation, Inc., 59 Temple Place, Suite 330, Boston,
 *  MA  02111-1307  USA
 */

#ifdef __CUDACC__

#include "cuComplex.h"
#include "cublas_v2.h"
#include <kernel.cu>
#include "createGPUHolders.cu"
#include <cuda_runtime_api.h>
#include <cufft.h>
//#include <cuda.h>

#else

#include <kernel.cpp>

#endif

#include <manager.hh>
#include <assert.h>
#include <iostream>
#include <complex>

#include "omp.h"
//#include "cuda_complex.hpp"
// TODO: CUTOFF PHASE WHEN IT STARTS TO GO BACK UP!!!

using namespace std;

#define BATCH 1

#ifdef __CUDACC__
void print_mem_info(){
        // show memory usage of GPU

        cudaError_t cuda_status;

        size_t free_byte ;

        size_t total_byte ;

        cuda_status = cudaMemGetInfo( &free_byte, &total_byte ) ;

        if ( cudaSuccess != cuda_status ){

            printf("Error: cudaMemGetInfo fails, %s \n", cudaGetErrorString(cuda_status) );

            exit(1);

        }



        double free_db = (double)free_byte ;

        double total_db = (double)total_byte ;

        double used_db = total_db - free_db ;

        printf("GPU memory usage: used = %f, free = %f MB, total = %f MB\n",

            used_db/1024.0/1024.0, free_db/1024.0/1024.0, total_db/1024.0/1024.0);
}

#endif

GBGPU::GBGPU (
    double *data_freqs_,
    cmplx *data_channel1_,
    cmplx *data_channel2_,
    cmplx *data_channel3_, int N_,
    double *channel1_ASDinv_, double *channel2_ASDinv_, double *channel3_ASDinv_,
    int nwalkers_,
    int ndevices_,
    double Tobs_,
    double dt_,
    int NP_,
    int data_stream_length_){

      Tobs = Tobs_;
      dt = dt_;
      NP = NP_;


    #pragma omp parallel
    {
      if (omp_get_thread_num() == 1) printf("NUM OMP THREADS: %d\n", omp_get_num_threads());
    }



    data_freqs = data_freqs_;
    N = N_;
    data_stream_length = data_stream_length_;
    channel1_ASDinv = channel1_ASDinv_;
    channel2_ASDinv = channel2_ASDinv_;
    channel3_ASDinv = channel3_ASDinv_;
    data_channel1 = data_channel1_;
    data_channel2 = data_channel2_;
    data_channel3 = data_channel3_;
    nwalkers = nwalkers_;
    ndevices = ndevices_;

    ndevices = ndevices_;


      gpuErrchk(cudaMalloc(&d_template_channel1, N*nwalkers*sizeof(agcmplx)));
      gpuErrchk(cudaMalloc(&d_template_channel2, N*nwalkers*sizeof(agcmplx)));
      gpuErrchk(cudaMalloc(&d_template_channel3, N*nwalkers*sizeof(agcmplx)));

      gpuErrchk(cudaMalloc(&d_data_freqs, N*sizeof(double)));

      gpuErrchk(cudaMalloc(&d_data_channel1, N*sizeof(agcmplx)));

      gpuErrchk(cudaMalloc(&d_data_channel2, N*sizeof(agcmplx)));

      gpuErrchk(cudaMalloc(&d_data_channel3, N*sizeof(agcmplx)));

      gpuErrchk(cudaMalloc(&d_channel1_ASDinv, N*sizeof(double)));

      gpuErrchk(cudaMalloc(&d_channel2_ASDinv, N*sizeof(double)));

      gpuErrchk(cudaMalloc(&d_channel3_ASDinv, N*sizeof(double)));


      h_wfm = new Waveform[nwalkers];

      for (int i=0; i<nwalkers; i++){
          h_wfm[i].NP = NP;
          h_wfm[i].T = Tobs;
          h_wfm[i].N = N;
          N = h_wfm[i].N;
          alloc_waveform(&h_wfm[i]);
      }
      gpuErrchk(cudaMalloc(&wfm, nwalkers*sizeof(Waveform)));



      gpuErrchk(cudaMemcpy(wfm, h_wfm, nwalkers*sizeof(Waveform), cudaMemcpyHostToDevice));


      //gpuErrchk(cudaMalloc(&X_buffer, 2*N*nwalkers*sizeof(double)));
      //gpuErrchk(cudaMalloc(&Y_buffer, 2*N*nwalkers*sizeof(double)));
      //gpuErrchk(cudaMalloc(&Z_buffer, 2*N*nwalkers*sizeof(double)));

      gpuErrchk(cudaMalloc(&XLS, 2*data_stream_length*sizeof(double)));
      gpuErrchk(cudaMalloc(&YLS, 2*data_stream_length*sizeof(double)));
      gpuErrchk(cudaMalloc(&ZLS, 2*data_stream_length*sizeof(double)));

      gpuErrchk(cudaMalloc(&XSL, 2*data_stream_length*sizeof(double)));
      gpuErrchk(cudaMalloc(&YSL, 2*data_stream_length*sizeof(double)));
      gpuErrchk(cudaMalloc(&ZSL, 2*data_stream_length*sizeof(double)));

      gpuErrchk(cudaMalloc(&d_params, NP*nwalkers*sizeof(double)));


      // for likelihood
      // --------------
  /*    stat = cublasCreate(&handle);
      if (stat != CUBLAS_STATUS_SUCCESS) {
              printf ("CUBLAS initialization failed\n");
              exit(0);
          }

          printf("CHECK1\n");*/

  if (cufftPlan1d(&plan, h_wfm->N, CUFFT_Z2Z, BATCH) != CUFFT_SUCCESS){
        	fprintf(stderr, "CUFFT error: Plan creation failed");
        	return;	}

  GBGPU::input_data(data_freqs, data_channel1,
                        data_channel2, data_channel3,
                        channel1_ASDinv, channel2_ASDinv,
                        channel3_ASDinv, N);

}


void GBGPU::input_data(double *data_freqs_, cmplx *data_channel1_,
                          cmplx *data_channel2_, cmplx *data_channel3_,
                          double *channel1_ASDinv_, double *channel2_ASDinv_,
                          double *channel3_ASDinv_, int N_){

    assert(N_ == N);

        gpuErrchk(cudaMemcpy(d_data_freqs, data_freqs_, N*sizeof(double), cudaMemcpyHostToDevice));

        gpuErrchk(cudaMemcpy(d_data_channel1, data_channel1_, N*sizeof(agcmplx), cudaMemcpyHostToDevice));

        gpuErrchk(cudaMemcpy(d_data_channel2, data_channel2_, N*sizeof(agcmplx), cudaMemcpyHostToDevice));

        gpuErrchk(cudaMemcpy(d_data_channel3, data_channel3_, N*sizeof(agcmplx), cudaMemcpyHostToDevice));

        gpuErrchk(cudaMemcpy(d_channel1_ASDinv, channel1_ASDinv_, N*sizeof(double), cudaMemcpyHostToDevice));

        gpuErrchk(cudaMemcpy(d_channel2_ASDinv, channel2_ASDinv_, N*sizeof(double), cudaMemcpyHostToDevice));

        gpuErrchk(cudaMemcpy(d_channel3_ASDinv, channel3_ASDinv_, N*sizeof(double), cudaMemcpyHostToDevice));
}

__global__
void fill_params(Waveform *wfm_trans, double *params, int nwalkers, int NP)
{
    Waveform *wfm;
  for (int walker_i = blockIdx.x * blockDim.x + threadIdx.x;
       walker_i < nwalkers;
       walker_i += blockDim.x * gridDim.x){
         wfm = &wfm_trans[walker_i];

         for (int i=0; i<NP; i++) wfm->params[0] = params[walker_i*NP + i];
         wfm->q  = (long)(wfm->params[0]);

  }
}


void GBGPU::Fast_GB(double *params_){//,double *XLS, double *YLS, double *ZLS,double* XSL, double* YSL, double* ZSL){

    gpuErrchk(cudaMemcpy(d_params, params_, nwalkers*NP*sizeof(double), cudaMemcpyHostToDevice));

      //gpuErrchk(cudaMemcpy(wfm, h_wfm, nwalkers*sizeof(Waveform), cudaMemcpyHostToDevice));

      int NUM_THREADS = 256;
      int num_blocks_basis_tensors = std::ceil((nwalkers + NUM_THREADS -1)/NUM_THREADS);

      fill_params<<<num_blocks_basis_tensors,NUM_THREADS>>>(wfm, d_params, nwalkers,NP);
      cudaDeviceSynchronize();
      gpuErrchk(cudaGetLastError());

    	get_basis_tensors<<<num_blocks_basis_tensors,NUM_THREADS>>>(wfm, nwalkers);      //  Tensor construction for building slowly evolving LISA response
      cudaDeviceSynchronize();
      gpuErrchk(cudaGetLastError());

      int num_blocks = std::ceil((h_wfm->N + NUM_THREADS -1)/NUM_THREADS);
      dim3 gridDim(num_blocks, nwalkers);
      GenWave<<<gridDim, NUM_THREADS>>>(wfm, h_wfm->N, nwalkers);
      cudaDeviceSynchronize();
      gpuErrchk(cudaGetLastError());

      fft_data(h_wfm, plan, nwalkers);

      unpack_data_1<<<gridDim, NUM_THREADS>>>(wfm, nwalkers);
      cudaDeviceSynchronize();
      gpuErrchk(cudaGetLastError());

      /*unpack_data_2<<<gridDim, NUM_THREADS>>>(wfm, nwalkers);
      cudaDeviceSynchronize();
      gpuErrchk(cudaGetLastError());*/

      XYZ_wrap<<<gridDim, NUM_THREADS>>>(wfm, nwalkers, N, dt, Tobs, XLS, YLS, ZLS, XSL, YSL, ZSL);
      cudaDeviceSynchronize();
      gpuErrchk(cudaGetLastError());
}

/*
Destructor
*/
GBGPU::~GBGPU() {

  gpuErrchk(cudaFree(d_data_freqs));
  gpuErrchk(cudaFree(d_data_channel1));
  gpuErrchk(cudaFree(d_data_channel2));
  gpuErrchk(cudaFree(d_data_channel3));

  gpuErrchk(cudaFree(d_template_channel1));
  gpuErrchk(cudaFree(d_template_channel2));
  gpuErrchk(cudaFree(d_template_channel3));

  gpuErrchk(cudaFree(d_channel1_ASDinv));
  gpuErrchk(cudaFree(d_channel2_ASDinv));
  gpuErrchk(cudaFree(d_channel3_ASDinv));
  free_waveform(wfm);
  //free(h_wfm);
  delete[] h_wfm;
  //cublasDestroy(handle);

//gpuErrchk(cudaFree(X_buffer));
//gpuErrchk(cudaFree(Y_buffer));
//gpuErrchk(cudaFree(Z_buffer));

gpuErrchk(cudaFree(d_params));

gpuErrchk(cudaFree(XLS));
gpuErrchk(cudaFree(YLS));
gpuErrchk(cudaFree(ZLS));

gpuErrchk(cudaFree(XSL));
gpuErrchk(cudaFree(YSL));
gpuErrchk(cudaFree(ZSL));

cufftDestroy(plan);
gpuErrchk(cudaFree(wfm));
}

int GetDeviceCount(){
    int num_device_check;
    #ifdef __CUDACC__
    cudaError_t cuda_status = cudaGetDeviceCount(&num_device_check);
    if (cudaSuccess != cuda_status) num_device_check = 0;
    #else
    num_device_check = 0;
    #endif
    printf("NUMBER OF DEVICES: %d\n", num_device_check);
    return num_device_check;
}
