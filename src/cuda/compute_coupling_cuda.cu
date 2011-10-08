/*
 !=====================================================================
 !
 !               S p e c f e m 3 D  V e r s i o n  2 . 0
 !               ---------------------------------------
 !
 !          Main authors: Dimitri Komatitsch and Jeroen Tromp
 !    Princeton University, USA and University of Pau / CNRS / INRIA
 ! (c) Princeton University / California Institute of Technology and University of Pau / CNRS / INRIA
 !                            April 2011
 !
 ! This program is free software; you can redistribute it and/or modify
 ! it under the terms of the GNU General Public License as published by
 ! the Free Software Foundation; either version 2 of the License, or
 ! (at your option) any later version.
 !
 ! This program is distributed in the hope that it will be useful,
 ! but WITHOUT ANY WARRANTY; without even the implied warranty of
 ! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 ! GNU General Public License for more details.
 !
 ! You should have received a copy of the GNU General Public License along
 ! with this program; if not, write to the Free Software Foundation, Inc.,
 ! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 !
 !=====================================================================
 */

#include <stdio.h>
#include <cuda.h>
#include <cublas.h>
#include <mpi.h>

#include <sys/time.h>
#include <sys/resource.h>

#include "config.h"
#include "mesh_constants_cuda.h"


/* ----------------------------------------------------------------------------------------------- */

// ACOUSTIC - ELASTIC coupling

/* ----------------------------------------------------------------------------------------------- */

__global__ void compute_coupling_acoustic_el_kernel(float* displ, 
                                                    float* potential_dot_dot_acoustic, 
                                                    int num_coupling_ac_el_faces,
                                                    int* coupling_ac_el_ispec,
                                                    int* coupling_ac_el_ijk, 
                                                    float* coupling_ac_el_normal,
                                                    float* coupling_ac_el_jacobian2Dw,
                                                    int* ibool,
                                                    int* ispec_is_inner, 
                                                    int phase_is_inner) {
  
  int igll = threadIdx.x; 
  int iface = blockIdx.x + gridDim.x*blockIdx.y; 
  
  int i,j,k,iglob,ispec;
  realw displ_x,displ_y,displ_z,displ_n;
  realw nx,ny,nz;
  realw jacobianw;
  
  if( iface < num_coupling_ac_el_faces){
  
    // don't compute points outside NGLLSQUARE==NGLL2==25  
    // way 2: no further check needed since blocksize = 25
    //  if(igll<NGLL2) {    
    
    // "-1" from index values to convert from Fortran-> C indexing
    ispec = coupling_ac_el_ispec[iface]-1;
    
    if(ispec_is_inner[ispec] == phase_is_inner ) {
      
      i = coupling_ac_el_ijk[INDEX3(NDIM,NGLL2,0,igll,iface)] - 1;
      j = coupling_ac_el_ijk[INDEX3(NDIM,NGLL2,1,igll,iface)] - 1;
      k = coupling_ac_el_ijk[INDEX3(NDIM,NGLL2,2,igll,iface)] - 1;
      iglob = ibool[INDEX4(5,5,5,i,j,k,ispec)]-  1;
      
      // elastic displacement on global point
      displ_x = displ[iglob*3] ; // (1,iglob)
      displ_y = displ[iglob*3+1] ; // (2,iglob)
      displ_z = displ[iglob*3+2] ; // (3,iglob)
      
      // gets associated normal on GLL point
      nx = coupling_ac_el_normal[INDEX3(NDIM,NGLL2,0,igll,iface)]; // (1,igll,iface)
      ny = coupling_ac_el_normal[INDEX3(NDIM,NGLL2,1,igll,iface)]; // (2,igll,iface)
      nz = coupling_ac_el_normal[INDEX3(NDIM,NGLL2,2,igll,iface)]; // (3,igll,iface)

      // calculates displacement component along normal
      // (normal points outwards of acoustic element)
      displ_n = displ_x*nx + displ_y*ny + displ_z*nz;
      
      
      // gets associated, weighted jacobian      
      jacobianw = coupling_ac_el_jacobian2Dw[INDEX2(NGLL2,igll,iface)];            
      
      //daniel
      //if( igll == 0 ) printf("gpu: %i %i %i %i %i %e \n",i,j,k,ispec,iglob,jacobianw);


      // continuity of pressure and normal displacement on global point
      
      // note: newark time scheme together with definition of scalar potential:
      //          pressure = - chi_dot_dot
      //          requires that this coupling term uses the updated displacement at time step [t+delta_t],
      //          which is done at the very beginning of the time loop
      //          (see e.g. Chaljub & Vilotte, Nissen-Meyer thesis...)
      //          it also means you have to calculate and update this here first before
      //          calculating the coupling on the elastic side for the acceleration...
      atomicAdd(&potential_dot_dot_acoustic[iglob],+ jacobianw*displ_n);
            
    }
  //  }  
  }
}

/* ----------------------------------------------------------------------------------------------- */

extern "C" 
void FC_FUNC_(compute_coupling_acoustic_el_cuda,
              COMPUTE_COUPLING_ACOUSTIC_EL_CUDA)(
                                            long* Mesh_pointer_f, 
                                            int* phase_is_innerf, 
                                            int* num_coupling_ac_el_facesf, 
                                            int* SIMULATION_TYPEf) {
  TRACE("compute_coupling_acoustic_el_cuda");
  //double start_time = get_time();
  
  Mesh* mp = (Mesh*)(*Mesh_pointer_f); //get mesh pointer out of fortran integer container
  int phase_is_inner            = *phase_is_innerf;
  int num_coupling_ac_el_faces  = *num_coupling_ac_el_facesf;
  int SIMULATION_TYPE           = *SIMULATION_TYPEf;
  
  // way 1: exact blocksize to match NGLLSQUARE
  int blocksize = 25; 
  
  int num_blocks_x = num_coupling_ac_el_faces;
  int num_blocks_y = 1;
  while(num_blocks_x > 65535) {
    num_blocks_x = ceil(num_blocks_x/2.0);
    num_blocks_y = num_blocks_y*2;
  }
  
  dim3 grid(num_blocks_x,num_blocks_y);
  dim3 threads(blocksize,1,1);

//daniel
// printf("gpu: %i %i %i \n",num_coupling_ac_el_faces,SIMULATION_TYPE,phase_is_inner);

    
  compute_coupling_acoustic_el_kernel<<<grid,threads>>>(mp->d_displ,
                                                       mp->d_potential_dot_dot_acoustic,
                                                       num_coupling_ac_el_faces,
                                                       mp->d_coupling_ac_el_ispec, 
                                                       mp->d_coupling_ac_el_ijk, 
                                                       mp->d_coupling_ac_el_normal,
                                                       mp->d_coupling_ac_el_jacobian2Dw, 
                                                       mp->d_ibool, 
                                                       mp->d_ispec_is_inner, 
                                                       phase_is_inner);
  
  //  adjoint simulations
  if (SIMULATION_TYPE == 3 ){  
    compute_coupling_acoustic_el_kernel<<<grid,threads>>>(mp->d_b_displ,
                                                          mp->d_b_potential_dot_dot_acoustic,
                                                          num_coupling_ac_el_faces,
                                                          mp->d_coupling_ac_el_ispec, 
                                                          mp->d_coupling_ac_el_ijk, 
                                                          mp->d_coupling_ac_el_normal,
                                                          mp->d_coupling_ac_el_jacobian2Dw, 
                                                          mp->d_ibool, 
                                                          mp->d_ispec_is_inner, 
                                                          phase_is_inner);
    
  }
  
#ifdef ENABLE_VERY_SLOW_ERROR_CHECKING  
  //double end_time = get_time();
  //printf("Elapsed time: %e\n",end_time-start_time);
  exit_on_cuda_error("compute_coupling_acoustic_el_kernel");
#endif
}


/* ----------------------------------------------------------------------------------------------- */

// ELASTIC - ACOUSTIC coupling

/* ----------------------------------------------------------------------------------------------- */

__global__ void compute_coupling_elastic_ac_kernel(float* potential_dot_dot_acoustic, 
                                                    float* accel, 
                                                    int num_coupling_ac_el_faces,
                                                    int* coupling_ac_el_ispec,
                                                    int* coupling_ac_el_ijk, 
                                                    float* coupling_ac_el_normal,
                                                    float* coupling_ac_el_jacobian2Dw,
                                                    int* ibool,
                                                    int* ispec_is_inner, 
                                                    int phase_is_inner) {
  
  int igll = threadIdx.x; 
  int iface = blockIdx.x + gridDim.x*blockIdx.y; 
  
  int i,j,k,iglob,ispec;
  realw pressure;
  realw nx,ny,nz;
  realw jacobianw;
  
  if( iface < num_coupling_ac_el_faces){
    
    // don't compute points outside NGLLSQUARE==NGLL2==25  
    // way 2: no further check needed since blocksize = 25
    //  if(igll<NGLL2) {    
    
    // "-1" from index values to convert from Fortran-> C indexing
    ispec = coupling_ac_el_ispec[iface]-1;
    
    if(ispec_is_inner[ispec] == phase_is_inner ) {
      
      i = coupling_ac_el_ijk[INDEX3(NDIM,NGLL2,0,igll,iface)] - 1;
      j = coupling_ac_el_ijk[INDEX3(NDIM,NGLL2,1,igll,iface)] - 1;
      k = coupling_ac_el_ijk[INDEX3(NDIM,NGLL2,2,igll,iface)] - 1;
      iglob = ibool[INDEX4(5,5,5,i,j,k,ispec)]-  1;
      
      // acoustic pressure on global point
      pressure = - potential_dot_dot_acoustic[iglob];
            
      // gets associated normal on GLL point
      nx = coupling_ac_el_normal[INDEX3(NDIM,NGLL2,0,igll,iface)]; // (1,igll,iface)
      ny = coupling_ac_el_normal[INDEX3(NDIM,NGLL2,1,igll,iface)]; // (2,igll,iface)
      nz = coupling_ac_el_normal[INDEX3(NDIM,NGLL2,2,igll,iface)]; // (3,igll,iface)
      
      // gets associated, weighted jacobian      
      jacobianw = coupling_ac_el_jacobian2Dw[INDEX2(NGLL2,igll,iface)];            
      
      //daniel
      //if( igll == 0 ) printf("gpu: %i %i %i %i %i %e \n",i,j,k,ispec,iglob,jacobianw);
      
      
      // continuity of displacement and pressure on global point
      //
      // note: newark time scheme together with definition of scalar potential:
      //          pressure = - chi_dot_dot
      //          requires that this coupling term uses the *UPDATED* pressure (chi_dot_dot), i.e.
      //          pressure at time step [t + delta_t]
      //          (see e.g. Chaljub & Vilotte, Nissen-Meyer thesis...)
      //          it means you have to calculate and update the acoustic pressure first before
      //          calculating this term...
      atomicAdd(&accel[iglob*3],+ jacobianw*nx*pressure);
      atomicAdd(&accel[iglob*3+1],+ jacobianw*ny*pressure);
      atomicAdd(&accel[iglob*3+2],+ jacobianw*nz*pressure);
    }
    //  }  
  }
}

/* ----------------------------------------------------------------------------------------------- */

extern "C" 
void FC_FUNC_(compute_coupling_elastic_ac_cuda,
              COMPUTE_COUPLING_ELASTIC_AC_CUDA)(
                                                 long* Mesh_pointer_f, 
                                                 int* phase_is_innerf, 
                                                 int* num_coupling_ac_el_facesf, 
                                                 int* SIMULATION_TYPEf) {
  TRACE("compute_coupling_elastic_ac_cuda");
  //double start_time = get_time();
  
  Mesh* mp = (Mesh*)(*Mesh_pointer_f); //get mesh pointer out of fortran integer container
  int phase_is_inner            = *phase_is_innerf;
  int num_coupling_ac_el_faces  = *num_coupling_ac_el_facesf;
  int SIMULATION_TYPE           = *SIMULATION_TYPEf;
  
  // way 1: exact blocksize to match NGLLSQUARE
  int blocksize = 25; 
  
  int num_blocks_x = num_coupling_ac_el_faces;
  int num_blocks_y = 1;
  while(num_blocks_x > 65535) {
    num_blocks_x = ceil(num_blocks_x/2.0);
    num_blocks_y = num_blocks_y*2;
  }
  
  dim3 grid(num_blocks_x,num_blocks_y);
  dim3 threads(blocksize,1,1);
  
  //daniel
  // printf("gpu: %i %i %i \n",num_coupling_ac_el_faces,SIMULATION_TYPE,phase_is_inner);
  
  
  compute_coupling_elastic_ac_kernel<<<grid,threads>>>(mp->d_potential_dot_dot_acoustic,
                                                       mp->d_accel,
                                                       num_coupling_ac_el_faces,
                                                       mp->d_coupling_ac_el_ispec, 
                                                       mp->d_coupling_ac_el_ijk, 
                                                       mp->d_coupling_ac_el_normal,
                                                       mp->d_coupling_ac_el_jacobian2Dw, 
                                                       mp->d_ibool, 
                                                       mp->d_ispec_is_inner, 
                                                       phase_is_inner);
  
  //  adjoint simulations
  if (SIMULATION_TYPE == 3 ){  
    compute_coupling_elastic_ac_kernel<<<grid,threads>>>(mp->d_b_potential_dot_dot_acoustic,
                                                         mp->d_b_accel,
                                                         num_coupling_ac_el_faces,
                                                         mp->d_coupling_ac_el_ispec, 
                                                         mp->d_coupling_ac_el_ijk, 
                                                         mp->d_coupling_ac_el_normal,
                                                         mp->d_coupling_ac_el_jacobian2Dw, 
                                                         mp->d_ibool, 
                                                         mp->d_ispec_is_inner, 
                                                         phase_is_inner);
    
  }
  
#ifdef ENABLE_VERY_SLOW_ERROR_CHECKING  
  //double end_time = get_time();
  //printf("Elapsed time: %e\n",end_time-start_time);
  exit_on_cuda_error("compute_coupling_elastic_ac_cuda");
#endif
}
