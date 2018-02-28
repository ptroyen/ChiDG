module bc_state_outlet_3dgiles_innerproduct
#include <messenger.h>
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: ZERO, ONE, TWO, HALF, ME, CYLINDRICAL
    use mod_fluid,              only: gam
    use mod_inv,                only: inv
    use mod_interpolation,      only: interpolate_linear, interpolate_linear_ad
    use mod_fgmres_standard,    only: fgmres_autodiff, fgmres_standard

    use type_point,             only: point_t
    use type_mesh,              only: mesh_t
    use type_bc_state,          only: bc_state_t
    use type_bc_patch,          only: bc_patch_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_properties,        only: properties_t
    use type_face_info,         only: face_info_t
    use mod_chidg_mpi,          only: IRANK
    use mod_interpolate,        only: interpolate_face_autodiff
    use mpi_f08,                only: MPI_REAL8, MPI_SUM, MPI_AllReduce, mpi_comm, MPI_INTEGER, MPI_BCast
    use ieee_arithmetic,        only: ieee_is_nan
    use DNAD_D
    implicit none





    !>  Name: Outlet - 3D Giles
    !!
    !!  Options:
    !!      : Average Pressure
    !!
    !!  Behavior:
    !!      
    !!  References:
    !!              
    !!  
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2018
    !!
    !----------------------------------------------------------------------------------------
    type, public, extends(bc_state_t) :: outlet_3dgiles_innerproduct_t

        complex(rk),    allocatable :: k(:)
        complex(rk),    allocatable :: A(:,:)
        complex(rk),    allocatable :: A_gq(:,:)
        complex(rk),    allocatable :: B(:,:)
        type(AD_D),     allocatable :: amp_real(:)
        type(AD_D),     allocatable :: amp_imag(:)

    contains

        procedure   :: init                 ! Set-up bc state with options/name etc.
        procedure   :: init_bc_coupling     ! Implement specialized initialization procedure
        procedure   :: compute_bc_state     ! boundary condition function implementation

        procedure   :: compute_averages
        procedure   :: read_eigendecomposition

    end type outlet_3dgiles_innerproduct_t
    !****************************************************************************************




contains



    !>
    !!
    !!  @author Nathan A. average_pressure 
    !!  @date   2/8/2017
    !!
    !--------------------------------------------------------------------------------
    subroutine init(self)
        class(outlet_3dgiles_innerproduct_t),   intent(inout) :: self
        
        !
        ! Set name, family
        !
        call self%set_name('Outlet - 3D Giles Innerproduct')
        call self%set_family('Outlet')


        !
        ! Add functions
        !
        call self%bcproperties%add('Average Pressure','Required')


    end subroutine init
    !********************************************************************************







    !>  Initialize boundary group coupling.
    !!
    !!  For this LODI-based outlet, each patch face is coupled with every other
    !!  face in the bc_group. This coupling occurs because each face uses an
    !!  average pressure that is computed over the group. The average pressure
    !!  calculation couples every element on the group. This coupling is initialized
    !!  here.
    !!
    !!  Coupling initialization:
    !!      1: each process loops through its local faces, initializes coupling
    !!         of all local faces with all other local faces.
    !!
    !!      2: loop through ranks in bc_COMM
    !!          a: iproc broadcasts information about its coupling to bc_COMM
    !!          b: all other procs receive from iproc and initialize parallel coupling
    !!
    !!  @author Nathan A. average_pressure
    !!  @date   4/18/2017
    !!
    !--------------------------------------------------------------------------------
    subroutine init_bc_coupling(self,mesh,group_ID,bc_COMM)
        class(outlet_3dgiles_innerproduct_t),    intent(inout)   :: self
        type(mesh_t),               intent(inout)   :: mesh
        integer(ik),                intent(in)      :: group_ID
        type(mpi_comm),             intent(in)      :: bc_COMM

        integer(ik) :: patch_ID, face_ID, elem_ID, patch_ID_coupled, face_ID_coupled,   &
                       idomain_g, idomain_l, ielement_g, ielement_l, iface,             &
                       bc_IRANK, bc_NRANK, ierr, iproc, nbc_elements,     &
                       ielem, neqns, nterms_s, ngq, ibc

        integer(ik) :: idomain_g_coupled, idomain_l_coupled, ielement_g_coupled, ielement_l_coupled, &
                       iface_coupled, proc_coupled

        real(rk),       allocatable :: interp_coords_def(:,:)
        real(rk),       allocatable :: areas(:)
        real(rk)                    :: total_area



        !
        ! For each face, initialize coupling with all faces on the current processor.
        !
        do patch_ID = 1,mesh%bc_patch_group(group_ID)%npatches()
            do face_ID = 1,mesh%bc_patch_group(group_ID)%patch(patch_ID)%nfaces()

                
                !
                ! Loop through, initialize coupling
                !
                do patch_ID_coupled = 1,mesh%bc_patch_group(group_ID)%npatches()
                    do face_ID_coupled = 1,mesh%bc_patch_group(group_ID)%patch(patch_ID)%nfaces()


                        !
                        ! Get block-element index of current face_ID_coupled
                        !
                        idomain_g  = mesh%bc_patch_group(group_ID)%patch(patch_ID_coupled)%idomain_g()
                        idomain_l  = mesh%bc_patch_group(group_ID)%patch(patch_ID_coupled)%idomain_l()
                        ielement_g = mesh%bc_patch_group(group_ID)%patch(patch_ID_coupled)%ielement_g(face_ID_coupled)
                        ielement_l = mesh%bc_patch_group(group_ID)%patch(patch_ID_coupled)%ielement_l(face_ID_coupled)
                        iface      = mesh%bc_patch_group(group_ID)%patch(patch_ID_coupled)%iface(     face_ID_coupled)


                        neqns      = mesh%domain(idomain_l)%faces(ielement_l,iface)%neqns
                        nterms_s   = mesh%domain(idomain_l)%faces(ielement_l,iface)%nterms_s
                        total_area = mesh%domain(idomain_l)%faces(ielement_l,iface)%total_area
                        areas      = mesh%domain(idomain_l)%faces(ielement_l,iface)%differential_areas
                        interp_coords_def   = mesh%domain(idomain_l)%faces(ielement_l,iface)%interp_coords_def



                        !
                        ! For the face (patch_ID,face_ID) add the element on (patch_ID_coupled,face_ID_coupled)
                        !
                        call mesh%bc_patch_group(group_ID)%patch(patch_ID)%add_coupled_element(face_ID, idomain_g,  &
                                                                                                        idomain_l,  &
                                                                                                        ielement_g, &
                                                                                                        ielement_l, &
                                                                                                        iface,      &
                                                                                                        IRANK)

                        call mesh%bc_patch_group(group_ID)%patch(patch_ID)%set_coupled_element_data(face_ID, idomain_g,     &
                                                                                                             ielement_g,    &
                                                                                                             neqns,         &
                                                                                                             nterms_s,      &
                                                                                                             total_area,    &
                                                                                                             areas,         &
                                                                                                             interp_coords_def)


                    end do ! face_ID_couple
                end do ! patch_ID_couple

            end do ! face_ID
        end do ! patch_ID







        !
        ! Get bc_NRANK, bc_IRANK from bc_COMM
        !
        call MPI_Comm_Size(bc_COMM, bc_NRANK, ierr)
        call MPI_Comm_Rank(bc_COMM, bc_IRANK, ierr)





        !
        ! Initialize coupling with faces on other processors
        !
        do iproc = 0,bc_NRANK-1



            !
            ! Send local elements out
            !
            if (iproc == bc_IRANK) then


                nbc_elements = mesh%bc_patch_group(group_ID)%nfaces()
                call MPI_Bcast(IRANK,        1, MPI_INTEGER, iproc, bc_COMM, ierr)
                call MPI_Bcast(nbc_elements, 1, MPI_INTEGER, iproc, bc_COMM, ierr)


                do patch_ID = 1,mesh%bc_patch_group(group_ID)%npatches()
                    do face_ID = 1,mesh%bc_patch_group(group_ID)%patch(patch_ID)%nfaces()

                        idomain_l  = mesh%bc_patch_group(group_ID)%patch(patch_ID)%idomain_l()
                        ielement_l = mesh%bc_patch_group(group_ID)%patch(patch_ID)%ielement_l(face_ID)
                        iface      = mesh%bc_patch_group(group_ID)%patch(patch_ID)%iface(face_ID)
                        
                        ! Broadcast element for coupling
                        call MPI_Bcast(mesh%bc_patch_group(group_ID)%patch(patch_ID)%idomain_g(),         1, MPI_INTEGER, iproc, bc_COMM, ierr)
                        call MPI_Bcast(mesh%bc_patch_group(group_ID)%patch(patch_ID)%idomain_l(),         1, MPI_INTEGER, iproc, bc_COMM, ierr)
                        call MPI_Bcast(mesh%bc_patch_group(group_ID)%patch(patch_ID)%ielement_g(face_ID), 1, MPI_INTEGER, iproc, bc_COMM, ierr)
                        call MPI_Bcast(mesh%bc_patch_group(group_ID)%patch(patch_ID)%ielement_l(face_ID), 1, MPI_INTEGER, iproc, bc_COMM, ierr)
                        call MPI_Bcast(mesh%bc_patch_group(group_ID)%patch(patch_ID)%iface(face_ID),      1, MPI_INTEGER, iproc, bc_COMM, ierr)


                        ! Broadcast auxiliary data
                        call MPI_Bcast(mesh%domain(idomain_l)%faces(ielement_l,iface)%neqns,      1, MPI_INTEGER, iproc, bc_COMM, ierr)
                        call MPI_Bcast(mesh%domain(idomain_l)%faces(ielement_l,iface)%nterms_s,   1, MPI_INTEGER, iproc, bc_COMM, ierr)
                        call MPI_Bcast(mesh%domain(idomain_l)%faces(ielement_l,iface)%total_area, 1, MPI_INTEGER, iproc, bc_COMM, ierr)

                        ngq = size(mesh%domain(idomain_l)%faces(ielement_l,iface)%interp_coords_def,1)
                        call MPI_Bcast(ngq,                                                                          1, MPI_INTEGER, iproc, bc_COMM, ierr)
                        call MPI_Bcast(mesh%domain(idomain_l)%faces(ielement_l,iface)%differential_areas,          ngq, MPI_INTEGER, iproc, bc_COMM, ierr)
                        call MPI_Bcast(mesh%domain(idomain_l)%faces(ielement_l,iface)%interp_coords_def(:,1),      ngq, MPI_INTEGER, iproc, bc_COMM, ierr)
                        call MPI_Bcast(mesh%domain(idomain_l)%faces(ielement_l,iface)%interp_coords_def(:,2),      ngq, MPI_INTEGER, iproc, bc_COMM, ierr)
                        call MPI_Bcast(mesh%domain(idomain_l)%faces(ielement_l,iface)%interp_coords_def(:,3),      ngq, MPI_INTEGER, iproc, bc_COMM, ierr)

                    end do ! face_ID
                end do ! patch_ID
            








            !
            ! All other processors recieve
            !
            else


                call MPI_Bcast(proc_coupled, 1, MPI_INTEGER, iproc, bc_COMM, ierr)
                call MPI_Bcast(nbc_elements, 1, MPI_INTEGER, iproc, bc_COMM, ierr)



                !
                ! For the face (patch_ID,face_ID) add each element from the sending proc
                !
                do ielem = 1,nbc_elements

                    ! Receive coupled element
                    call MPI_BCast(idomain_g_coupled,  1, MPI_INTEGER, iproc, bc_COMM, ierr)
                    call MPI_BCast(idomain_l_coupled,  1, MPI_INTEGER, iproc, bc_COMM, ierr)
                    call MPI_BCast(ielement_g_coupled, 1, MPI_INTEGER, iproc, bc_COMM, ierr)
                    call MPI_BCast(ielement_l_coupled, 1, MPI_INTEGER, iproc, bc_COMM, ierr)
                    call MPI_BCast(iface_coupled,      1, MPI_INTEGER, iproc, bc_COMM, ierr)


                    ! Receive auxiliary data
                    call MPI_BCast(neqns,     1, MPI_INTEGER, iproc, bc_COMM, ierr)
                    call MPI_BCast(nterms_s,  1, MPI_INTEGER, iproc, bc_COMM, ierr)
                    call MPI_BCast(total_area,1, MPI_INTEGER, iproc, bc_COMM, ierr)


                    call MPI_BCast(ngq, 1, MPI_INTEGER, iproc, bc_COMM, ierr)
                    if (allocated(areas) ) deallocate(areas, interp_coords_def)
                    allocate(areas(ngq), interp_coords_def(ngq,3), stat=ierr)
                    if (ierr /= 0) call AllocationError


                    call MPI_BCast(areas,           ngq, MPI_REAL8, iproc, bc_COMM, ierr)
                    call MPI_BCast(interp_coords_def(:,1), ngq, MPI_REAL8, iproc, bc_COMM, ierr)
                    call MPI_BCast(interp_coords_def(:,2), ngq, MPI_REAL8, iproc, bc_COMM, ierr)
                    call MPI_BCast(interp_coords_def(:,3), ngq, MPI_REAL8, iproc, bc_COMM, ierr)


                    !
                    ! Each face on the current proc adds the off-processor element to their list 
                    ! of coupled elems
                    !
                    do patch_ID = 1,mesh%bc_patch_group(group_ID)%npatches()
                        do face_ID = 1,mesh%bc_patch_group(group_ID)%patch(patch_ID)%nfaces()

                            call mesh%bc_patch_group(group_ID)%patch(patch_ID)%add_coupled_element(face_ID, idomain_g_coupled,     &
                                                                                                            idomain_l_coupled,     &
                                                                                                            ielement_g_coupled,    &
                                                                                                            ielement_l_coupled,    &
                                                                                                            iface_coupled,         &
                                                                                                            proc_coupled)

                            call mesh%bc_patch_group(group_ID)%patch(patch_ID)%set_coupled_element_data(face_ID, idomain_g_coupled,     &
                                                                                                                 ielement_g_coupled,    &
                                                                                                                 neqns,                 &
                                                                                                                 nterms_s,              &
                                                                                                                 total_area,            &
                                                                                                                 areas,                 &
                                                                                                                 interp_coords_def)





                        end do ! face_ID
                    end do ! patch_ID

                end do !ielem




            end if




            call MPI_Barrier(bc_COMM,ierr)
        end do







    end subroutine init_bc_coupling
    !******************************************************************************************






    !>  Update the area-averaged pressure for the boundary condition.
    !!
    !!  @author Nathan A. average_pressure
    !!  @date   3/31/2017
    !!
    !!
    !-------------------------------------------------------------------------------------------
    subroutine compute_averages(self,worker,bc_COMM, vel1_avg, vel2_avg, vel3_avg, density_avg, p_avg)
        class(outlet_3dgiles_innerproduct_t),    intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(mpi_comm),             intent(in)      :: bc_COMM
        type(AD_D),                 intent(inout)   :: vel1_avg
        type(AD_D),                 intent(inout)   :: vel2_avg
        type(AD_D),                 intent(inout)   :: vel3_avg
        type(AD_D),                 intent(inout)   :: density_avg
        type(AD_D),                 intent(inout)   :: p_avg

        type(face_info_t)   :: face_info

        type(AD_D), allocatable,    dimension(:)    ::  &
            density, mom_1, mom_2, mom_3, energy, p,    &
            u, v, w, c, M, vmag
        type(AD_D)  :: face_p, face_M, p_integral, u_integral, v_integral, w_integral, &
                       density_integral, face_density, face_u, face_v, face_w


        integer(ik) :: ipatch, iface_bc, idomain_l, ielement_l, iface, ierr, itime, &
                       idensity, imom1, imom2, imom3, ienergy, group_ID, patch_ID, face_ID, &
                       icoupled, idomain_g_coupled, idomain_l_coupled, ielement_g_coupled,  &
                       ielement_l_coupled, iface_coupled

        real(rk),   allocatable,    dimension(:)    :: weights, areas, r
        real(rk)    :: face_area, total_area



        !
        ! Zero integrated quantities
        !
        total_area = ZERO


        ! Get location on domain
        idomain_l  = worker%element_info%idomain_l
        ielement_l = worker%element_info%ielement_l
        iface      = worker%iface

        ! Get location on bc_patch_group
        group_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%group_ID
        patch_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%patch_ID
        face_ID  = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%face_ID




        !
        ! Loop through coupled faces and compute their contribution to the average pressure
        !
        do icoupled = 1,worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%ncoupled_elements(face_ID)

            !
            ! Get solution
            !
            idensity = 1
            imom1    = 2
            imom2    = 3
            imom3    = 4
            ienergy  = 5
            itime    = 1


            !
            ! Get face info from coupled element we want to interpolate from
            !
            idomain_g_coupled  = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_g( icoupled)
            idomain_l_coupled  = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%idomain_l( icoupled)
            ielement_g_coupled = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_g(icoupled)
            ielement_l_coupled = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%ielement_l(icoupled)
            iface_coupled      = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%iface(     icoupled)

            face_info%idomain_g  = idomain_g_coupled
            face_info%idomain_l  = idomain_l_coupled
            face_info%ielement_g = ielement_g_coupled
            face_info%ielement_l = ielement_l_coupled
            face_info%iface      = iface_coupled

            
            !
            ! Interpolate coupled element solution on face of coupled element
            !
            density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,face_info,worker%function_info, idensity, itime, 'value', ME)
            mom_1   = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,face_info,worker%function_info, imom1,    itime, 'value', ME)
            mom_2   = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,face_info,worker%function_info, imom2,    itime, 'value', ME)
            mom_3   = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,face_info,worker%function_info, imom3,    itime, 'value', ME)
            energy  = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,face_info,worker%function_info, ienergy,  itime, 'value', ME)

            r = worker%coordinate('1','boundary')
            if (worker%coordinate_system() == 'Cylindrical') then
                mom_2 = mom_2 / r
            end if


            
            !
            ! Compute quantities for averaging
            !
            u = mom_1 / density
            v = mom_2 / density
            w = mom_3 / density
            !p = (gam - ONE)*(energy - HALF*density*(u*u + v*v + w*w))
            p = (gam-ONE)*(energy - HALF*((mom_1*mom_1) + (mom_2*mom_2) + (mom_3*mom_3))/density)
            c = sqrt(gam * p / density)
            vmag = sqrt(u*u + v*v + w*w)
            M = vmag/c


            !
            ! Get weights + areas
            !
            weights   = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%basis_s%weights_face(iface_coupled)
            areas     = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%data(icoupled)%areas
            face_area = worker%mesh%bc_patch_group(group_ID)%patch(patch_ID)%coupling(face_ID)%data(icoupled)%total_area



            !
            ! Integrate and contribute to average
            !
            face_density = sum(density * areas * weights)
            face_u       = sum(u       * areas * weights)
            face_v       = sum(v       * areas * weights)
            face_w       = sum(w       * areas * weights)
            face_p       = sum(p       * areas * weights)



            if (allocated(u_integral%xp_ad_)) then
                u_integral = u_integral + face_u
            else
                u_integral = face_u
            end if

            if (allocated(v_integral%xp_ad_)) then
                v_integral = v_integral + face_v
            else
                v_integral = face_v
            end if

            if (allocated(w_integral%xp_ad_)) then
                w_integral = w_integral + face_w
            else
                w_integral = face_w
            end if

            if (allocated(p_integral%xp_ad_)) then
                p_integral = p_integral + face_p
            else
                p_integral = face_p
            end if

            if (allocated(density_integral%xp_ad_)) then
                density_integral = density_integral + face_density
            else
                density_integral = face_density
            end if


            total_area = total_area + face_area


        end do !icoupled



                                                      
        !                                             
        ! Compute average pressure:
        !   area-weighted pressure integral over the total area
        !   
        !
        vel1_avg    = u_integral       / total_area
        vel2_avg    = v_integral       / total_area
        vel3_avg    = w_integral       / total_area
        density_avg = density_integral / total_area
        p_avg       = p_integral       / total_area



    end subroutine compute_averages
    !*******************************************************************************************







    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2018
    !!
    !-----------------------------------------------------------------------------------
    subroutine read_eigendecomposition(self,worker,prop,bc_COMM, du_c_gq, du_ad_gq)
        class(outlet_3dgiles_innerproduct_t),   intent(inout)   :: self
        type(chidg_worker_t),                   intent(inout)   :: worker
        class(properties_t),                    intent(inout)   :: prop
        type(mpi_comm),                         intent(in)      :: bc_COMM
        type(AD_D), allocatable,                intent(inout)   :: du_c_gq(:)
        type(AD_D), allocatable,                intent(inout)   :: du_ad_gq(:)

        !integer, parameter :: ni = 4
        integer, parameter :: ni = 1
        integer, parameter :: nfields = 5

        integer     :: nr, nvectors, ierr, handle, ivec, ifield, ai_ind, a_s, a_e, inode, ngq, nvec, i

        complex(rk),    allocatable :: k(:)
        complex(rk),    allocatable :: A(:,:), B(:,:)
        type(point_t),  allocatable :: coords(:)
        real(rk),       allocatable :: r(:), r_gq(:), test(:), ref_coords(:,:), midpoint(:)
        real(rk)                    :: real_val, imag_val

        type(AD_D), allocatable, dimension(:)   ::  &
            density, mom1, mom2, mom3, energy,      &
            vel1, vel2, vel3, p, q, amp,            &
            ddensity, dvel1, dvel2, dvel3, dp, U_hat, du_a, du_ad, du_c

        type(AD_D)  :: density_avg, vel1_avg, vel2_avg, vel3_avg, p_avg

        namelist /sizes/  nr, nvectors
        namelist /eigendecomposition/ k, r, A, B



        ! Read number of vectors
        open(newunit=handle,form='formatted',file='test.dat')
        read(handle,nml=sizes)

        ! Allocate storage
        if (allocated(k)) deallocate(k)
        if (allocated(r)) deallocate(r)
        if (allocated(A)) deallocate(A)
        if (allocated(B)) deallocate(B)
        allocate(k(nvectors), r(nr), A(nfields*nr,nvectors), B(nfields*nr,nvectors), stat=ierr)
        if (ierr /= 0) call AllocationError


        ! Read eigenvalues, eigenvectors
        read(handle,nml=eigendecomposition)
        close(handle)

        ! Store to bc object
        self%k = k
        self%A = A
        self%B = B

        ! Get physical coordinates at midpoint of bc face
        midpoint = worker%mesh%domain(worker%element_info%idomain_l)%elems(worker%element_info%ielement_l)%physical_point([ZERO,ZERO,ONE],'Deformed')

        ! Get location in reference space for physical radial coordinate locations
        ! where the eigenvectors are evaluated at so we can interpolate the solution
        ! to those locations.
        allocate(ref_coords(size(r),3), stat=ierr)
        if (ierr /= 0) call AllocationError
        do i = 1,size(r)
            ref_coords(i,:) = worker%mesh%domain(worker%element_info%idomain_l)%elems(worker%element_info%ielement_l)%computational_point([r(i), midpoint(2), midpoint(3)])
            if (any(ieee_is_nan(ref_coords(i,:)))) call chidg_signal_two(FATAL,"bc_state_outlet_3dgiles_innerproduct: couldn't find discrete point in reference space.",i,ref_coords(i,1))
        end do


        !
        ! Interpolate solution to radial locations 
        !
        density = worker%interpolate_field('Density',    ref_coords)
        mom1    = worker%interpolate_field('Momentum-1', ref_coords)
        mom2    = worker%interpolate_field('Momentum-2', ref_coords)
        mom3    = worker%interpolate_field('Momentum-3', ref_coords)
        energy  = worker%interpolate_field('Energy',     ref_coords)
        mom2 = mom2/r


        !
        ! Compute boundary averages
        !
        call self%compute_averages(worker,bc_COMM, vel1_avg, vel2_avg, vel3_avg, density_avg, p_avg)


        !
        ! Compute primitive variables
        !
        vel1 = mom1/density
        vel2 = mom2/density
        vel3 = mom3/density
        p = (gam-ONE)*(energy - HALF*((mom1*mom1) + (mom2*mom2) + (mom3*mom3))/density)

        
        !
        ! Compute primitive variable perturbation about average state
        !
        ddensity = density - density_avg
        dvel1    = vel1    - vel1_avg
        !dvel2    = vel2    - vel2_avg
        dvel2    = vel2 ! any vtheta is considered as a perturbation
        dvel3    = vel3    - vel3_avg
        dp       = p       - p_avg

        U_hat = [ddensity, dvel1, dvel2, dvel3, dp]


        !
        ! Compute modal amplitudes via inner product of U_hat with left eigenvectors, vl
        !
        if (allocated(self%amp_real)) deallocate(self%amp_real, self%amp_imag)
        allocate(self%amp_real(size(B,2)), self%amp_imag(size(B,2)), stat=ierr)
        if (ierr /= 0) call AllocationError

!        do ivec = 1,size(B,2)
!            call project_to_eigenmodes(self%amp_real(ivec), self%amp_imag(ivec), B(:,ivec), U_hat)
!        end do
        call project_to_eigenmodes(self%amp_real, self%amp_imag, A, B, U_hat)

        print*, 'amp: ', self%amp_real(:)%x_ad_


!        !
!        ! Compute acoustic perturbation
!        !
!        du_a = [ddensity, dvel1, dvel2, dvel3, dp]
!        du_a(:) = ZERO
!        do ivec = 1,size(self%A,2)
!            du_a = du_a  +  realpart(self%A(:,ivec))*self%amp_real(ivec)  -  imagpart(self%A(:,ivec))*self%amp_imag(ivec)
!        end do
!
!
!        !
!        ! Compute convected perturbation
!        !
!        du_c = U_hat - du_a
!
!
!        !print*, 'AMP before:', self%amp_real(:)%x_ad_
!
!        !
!        ! Zero out amplitude of all upstream-traveling eigenmodes
!        !
!        do i = 1,size(self%amp_real)
!            if (imagpart(self%k(i)) < 0.) then
!                self%amp_real(i) = ZERO
!                self%amp_imag(i) = ZERO
!            end if
!        end do
!    
!        !print*, 'AMP after:', self%amp_real(:)%x_ad_
!
!        !
!        ! Compute downstream-traveling acoustic perturbation
!        !
!        du_ad = [ddensity, dvel1, dvel2, dvel3, dp]
!        du_ad(:) = ZERO
!        do ivec = 1,size(self%A,2)
!            du_ad = du_ad  +  realpart(self%A(:,ivec))*self%amp_real(ivec)  -  imagpart(self%A(:,ivec))*self%amp_imag(ivec)
!        end do
!        
!
!
!        !
!        ! Interpolate du_c, du_ad from eigenvector discretization to GQ nodes.
!        !
!        coords = worker%coords()
!        ngq = size(coords)
!        if (allocated(du_c_gq)) deallocate(du_c_gq, du_ad_gq)
!        allocate(du_c_gq(ngq*nfields), du_ad_gq(ngq*nfields), stat=ierr)
!        if (ierr /= 0) call AllocationError
!
!        du_c_gq(:)  = du_c(1)
!        du_ad_gq(:) = du_c(1)
!        du_c_gq  = ZERO
!        du_ad_gq = ZERO
!        do ifield = 1,nfields
!            do inode = 1,ngq
!                a_s = 1 + nr*(ifield-1)
!                a_e = a_s + (nr-1)
!                ai_ind = 1 + (inode-1) + ngq*(ifield-1)
!                du_c_gq(ai_ind)  = interpolate_linear_ad(r,du_c( a_s:a_e),coords(inode)%c1_)
!                du_ad_gq(ai_ind) = interpolate_linear_ad(r,du_ad(a_s:a_e),coords(inode)%c1_)
!            end do
!        end do


        !
        ! Construct interpolation matrix for eigenvectors to quadrature nodes
        !
        coords = worker%coords()
        ngq = size(coords)
        if (allocated(self%A_gq)) deallocate(self%A_gq)
        allocate(self%A_gq(ngq*nfields,nvectors), stat=ierr)
        if (ierr /= 0) call AllocationError


        do ivec = 1,size(self%A_gq,2)
            do ifield = 1,nfields
                do inode = 1,ngq
                    a_s = 1 + nr*(ifield-1)
                    a_e = a_s + (nr-1)
                    ai_ind = 1 + (inode-1) + ngq*(ifield-1)

                    real_val = interpolate_linear(r,realpart(self%A(a_s:a_e,ivec)),coords(inode)%c1_)
                    imag_val = interpolate_linear(r,imagpart(self%A(a_s:a_e,ivec)),coords(inode)%c1_)

                    self%A_gq(ai_ind,ivec) = cmplx(real_val, imag_val)
                end do
            end do
        end do



    end subroutine read_eigendecomposition
    !***********************************************************************************







    !>  
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/8/2018
    !!
    !!  @param[in]      worker  Interface for geometry, cache, integration, etc.
    !!  @param[inout]   prop    properties_t object containing equations and material_t objects
    !!
    !-------------------------------------------------------------------------------------------
    subroutine compute_bc_state(self,worker,prop,bc_COMM)
        class(outlet_3dgiles_innerproduct_t),   intent(inout)   :: self
        type(chidg_worker_t),                   intent(inout)   :: worker
        class(properties_t),                    intent(inout)   :: prop
        type(mpi_comm),                         intent(in)      :: bc_COMM


        ! Storage at quadrature nodes
        type(AD_D), allocatable, dimension(:)   ::                                      &
            density_m,  mom1_m,  mom2_m,  mom3_m,  energy_m,                            &
            density_bc, mom1_bc, mom2_bc, mom3_bc, energy_bc,                           &
            grad1_density_m, grad1_mom1_m, grad1_mom2_m, grad1_mom3_m, grad1_energy_m,  &
            grad2_density_m, grad2_mom1_m, grad2_mom2_m, grad2_mom3_m, grad2_energy_m,  &
            grad3_density_m, grad3_mom1_m, grad3_mom2_m, grad3_mom3_m, grad3_energy_m,  &
            vel1_bc, vel2_bc, vel3_bc, p_bc,                                            &
            vel1_m,  vel2_m,  vel3_m,  p_m,                                             &
            ddensity,       dvel1,      dvel2,      dvel3,      dp,                     &
            ddensity_d,     dvel1_d,    dvel2_d,    dvel3_d,    dp_d,                   &
            ddensity_c,     dvel1_c,    dvel2_c,    dvel3_c,    dp_c,                   &
            ddensity_a,     dvel1_a,    dvel2_a,    dvel3_a,    dp_a,                   &
            ddensity_ad,    dvel1_ad,   dvel2_ad,   dvel3_ad,   dp_ad,                  &
            c1, c2, c3, c4, du_a, du_ad, du_c_gq, du_ad_gq


        type(AD_D)  :: p_avg, vel1_avg, vel2_avg, vel3_avg, density_avg, M_avg, c_avg, &
                       c4_1d, ddensity_mean, dvel1_mean, dvel2_mean, dvel3_mean, dp_mean

        real(rk),   allocatable, dimension(:)   ::  p_user, r
        integer :: i, ngq, ivec




        !
        !
        !
        call self%read_eigendecomposition(worker,prop,bc_COMM,du_c_gq, du_ad_gq)

        !
        ! Get back pressure from function.
        !
        p_user = self%bcproperties%compute('Average Pressure',worker%time(),worker%coords())



        !
        ! Interpolate interior solution to face quadrature nodes
        !
        density_m = worker%get_field('Density'   , 'value', 'face interior')
        mom1_m    = worker%get_field('Momentum-1', 'value', 'face interior')
        mom2_m    = worker%get_field('Momentum-2', 'value', 'face interior')
        mom3_m    = worker%get_field('Momentum-3', 'value', 'face interior')
        energy_m  = worker%get_field('Energy'    , 'value', 'face interior')



        grad1_density_m = worker%get_field('Density'   , 'grad1', 'face interior')
        grad2_density_m = worker%get_field('Density'   , 'grad2', 'face interior')
        grad3_density_m = worker%get_field('Density'   , 'grad3', 'face interior')

        grad1_mom1_m    = worker%get_field('Momentum-1', 'grad1', 'face interior')
        grad2_mom1_m    = worker%get_field('Momentum-1', 'grad2', 'face interior')
        grad3_mom1_m    = worker%get_field('Momentum-1', 'grad3', 'face interior')

        grad1_mom2_m    = worker%get_field('Momentum-2', 'grad1', 'face interior')
        grad2_mom2_m    = worker%get_field('Momentum-2', 'grad2', 'face interior')
        grad3_mom2_m    = worker%get_field('Momentum-2', 'grad3', 'face interior')

        grad1_mom3_m    = worker%get_field('Momentum-3', 'grad1', 'face interior')
        grad2_mom3_m    = worker%get_field('Momentum-3', 'grad2', 'face interior')
        grad3_mom3_m    = worker%get_field('Momentum-3', 'grad3', 'face interior')
        
        grad1_energy_m  = worker%get_field('Energy'    , 'grad1', 'face interior')
        grad2_energy_m  = worker%get_field('Energy'    , 'grad2', 'face interior')
        grad3_energy_m  = worker%get_field('Energy'    , 'grad3', 'face interior')





        !
        ! Store boundary gradient state. Grad(Q_bc). Do this here, before we
        ! compute any transformations for cylindrical.
        !
        call worker%store_bc_state('Density'   , grad1_density_m, 'grad1')
        call worker%store_bc_state('Density'   , grad2_density_m, 'grad2')
        call worker%store_bc_state('Density'   , grad3_density_m, 'grad3')
                                                
        call worker%store_bc_state('Momentum-1', grad1_mom1_m,    'grad1')
        call worker%store_bc_state('Momentum-1', grad2_mom1_m,    'grad2')
        call worker%store_bc_state('Momentum-1', grad3_mom1_m,    'grad3')
                                                
        call worker%store_bc_state('Momentum-2', grad1_mom2_m,    'grad1')
        call worker%store_bc_state('Momentum-2', grad2_mom2_m,    'grad2')
        call worker%store_bc_state('Momentum-2', grad3_mom2_m,    'grad3')
                                                
        call worker%store_bc_state('Momentum-3', grad1_mom3_m,    'grad1')
        call worker%store_bc_state('Momentum-3', grad2_mom3_m,    'grad2')
        call worker%store_bc_state('Momentum-3', grad3_mom3_m,    'grad3')
                                                
        call worker%store_bc_state('Energy'    , grad1_energy_m,  'grad1')
        call worker%store_bc_state('Energy'    , grad2_energy_m,  'grad2')
        call worker%store_bc_state('Energy'    , grad3_energy_m,  'grad3')




        !
        ! Account for cylindrical. Get tangential momentum from angular momentum.
        !
        r = worker%coordinate('1','boundary')
        if (worker%coordinate_system() == 'Cylindrical') then
            mom2_m = mom2_m / r
            grad1_mom2_m = (grad1_mom2_m/r) - mom2_m/r
            grad2_mom2_m = (grad2_mom2_m/r)
            grad3_mom2_m = (grad3_mom2_m/r)
        end if



        !
        ! Update average pressure
        !
        call self%compute_averages(worker,bc_COMM,vel1_avg, vel2_avg, vel3_avg, density_avg, p_avg)
        c_avg = sqrt(gam*p_avg/density_avg)



        !
        ! Compute update for average quantities
        !
        ! Initialize derivatives and set to zero
        dvel1_mean = density_m(1)
        dvel2_mean = density_m(1)
        dvel3_mean = density_m(1)
        dvel1_mean = ZERO
        dvel2_mean = ZERO
        dvel3_mean = ZERO


        !c4_1d         = -TWO*(p_avg - p_user(1))
        !ddensity_mean =  c4_1d/(TWO*c_avg*c_avg)
        !dvel1_mean       = -c4_1d/(TWO*density_avg*c_avg)
        !dp_mean       =  HALF*c4_1d
        c4_1d         = -TWO*(p_avg - p_user(1))
        ddensity_mean =  c4_1d/(TWO*c_avg*c_avg)
        dvel3_mean    = -c4_1d/(TWO*density_avg*c_avg)
        dp_mean       =  HALF*c4_1d


        !
        ! Get primitive variables
        !
        vel1_m = mom1_m/density_m
        vel2_m = mom2_m/density_m
        vel3_m = mom3_m/density_m
        p_m = worker%get_field('Pressure', 'value', 'face interior')



        !
        ! Compute perturbation from avg
        !
        ddensity = density_m - density_avg
        dvel1    = vel1_m    - vel1_avg
        !dvel2    = vel2_m    - vel2_avg
        dvel2    = vel2_m    ! any vtheta is considered a perturbation
        dvel3    = vel3_m    - vel3_avg
        dp       = p_m       - p_avg


        !-------------------------------------
        
        !
        ! Reconstruct downstream acoustic part of perturbation onto quadrature nodes
        !
        ngq = size(density_m)
        du_a = [ddensity, dvel1, dvel2, dvel3, dp]
        du_a(:) = ZERO
        do ivec = 1,size(self%A_gq,2)
            du_a = du_a  +  realpart(self%A_gq(:,ivec))*self%amp_real(ivec)  -  imagpart(self%A_gq(:,ivec))*self%amp_imag(ivec)
        end do

        ddensity_a = du_a(1+0*ngq:1*ngq)
        dvel1_a    = du_a(1+1*ngq:2*ngq)
        dvel2_a    = du_a(1+2*ngq:3*ngq)
        dvel3_a    = du_a(1+3*ngq:4*ngq)
        dp_a       = du_a(1+4*ngq:5*ngq)


        !
        ! Compute convected part of the perturbation by subtracting the acoustic perturbation
        !
        ddensity_c = ddensity - ddensity_a
        dvel1_c    = dvel1    - dvel1_a
        dvel2_c    = dvel2    - dvel2_a
        dvel3_c    = dvel3    - dvel3_a
        dp_c       = dp       - dp_a


        ! Now zero out amplitude of all upstream-traveling eigenmodes
        do i = 1,size(self%amp_real)
            if (imagpart(self%k(i)) > 0.) then
                self%amp_real(i) = ZERO
                self%amp_imag(i) = ZERO
            end if
        end do
    

        ! Interpolate downstream-traveling acoustic perturbation onto quadrature nodes
        du_ad = [ddensity, dvel1, dvel2, dvel3, dp]
        du_ad(:) = ZERO
        do ivec = 1,size(self%A_gq,2)
            du_ad = du_ad  +  realpart(self%A_gq(:,ivec))*self%amp_real(ivec)  -  imagpart(self%A_gq(:,ivec))*self%amp_imag(ivec)
        end do

        ddensity_ad = du_ad(1+0*ngq:1*ngq)
        dvel1_ad    = du_ad(1+1*ngq:2*ngq)
        dvel2_ad    = du_ad(1+2*ngq:3*ngq)
        dvel3_ad    = du_ad(1+3*ngq:4*ngq)
        dp_ad       = du_ad(1+4*ngq:5*ngq)


        !-------------------------------------

!        !
!        ! Pull out primitive parts of downstream acoustic waves
!        !
!        ngq = size(density_m)
!        ddensity_ad = du_ad_gq(1 + 0*ngq:1*ngq)
!        dvel1_ad    = du_ad_gq(1 + 1*ngq:2*ngq)
!        dvel2_ad    = du_ad_gq(1 + 2*ngq:3*ngq)
!        dvel3_ad    = du_ad_gq(1 + 3*ngq:4*ngq)
!        dp_ad       = du_ad_gq(1 + 4*ngq:5*ngq)
!
!        ddensity_c  = du_c_gq(1 + 0*ngq:1*ngq)
!        dvel1_c     = du_c_gq(1 + 1*ngq:2*ngq)
!        dvel2_c     = du_c_gq(1 + 2*ngq:3*ngq)
!        dvel3_c     = du_c_gq(1 + 3*ngq:4*ngq)
!        dp_c        = du_c_gq(1 + 4*ngq:5*ngq)










        !
        ! Construct boundary state from:
        !   average  +  
        !   average_update(1d characteristics)  +  
        !   convected 2D perturbation  +  
        !   downstream-traveling 2D acoustic perturbation
        !
        density_bc = density_m
        vel1_bc    = density_m
        vel2_bc    = density_m
        vel3_bc    = density_m
        p_bc       = density_m
        do i = 1,size(ddensity_c)

!            density_bc(i) = density_avg  +  ddensity_mean  +  ddensity(i)
!            vel1_bc(i)    = vel1_avg     +  dvel1_mean     +  dvel1(i)
!            vel2_bc(i)    = vel2_avg     +  dvel2_mean     +  dvel2(i)
!            vel3_bc(i)    = vel3_avg     +  dvel3_mean     +  dvel3(i)
!            p_bc(i)       = p_avg        +  dp_mean        +  dp(i)


!            print*, ddensity_c(i)%x_ad_, dvel1_c(i)%x_ad_, dvel2_c(i)%x_ad_, dvel3_c(i)%x_ad_, dp_c(i)%x_ad_
!            print*, ddensity_ad(i)%x_ad_, dvel1_ad(i)%x_ad_, dvel2_ad(i)%x_ad_, dvel3_ad(i)%x_ad_, dp_ad(i)%x_ad_

            density_bc(i) = density_avg  +  ddensity_mean  +  ddensity_c(i)  +  ddensity_ad(i)
            vel1_bc(i)    = vel1_avg     +  dvel1_mean     +  dvel1_c(i)     +  dvel1_ad(i)
            !vel2_bc(i)    = vel2_avg     +  dvel2_mean     +  dvel2_c(i)     +  dvel2_ad(i)
            !vel2_bc(i)    = vel2_m(i)
            vel2_bc(i)    = dvel2_c(i)   +  dvel2_ad(i)
            vel3_bc(i)    = vel3_avg     +  dvel3_mean     +  dvel3_c(i)     +  dvel3_ad(i)
            p_bc(i)       = p_avg        +  dp_mean        +  dp_c(i)        +  dp_ad(i)
        
!            density_bc(i) = density_avg  +  ddensity_mean  +  ddensity_d(i)  
!            vel1_bc(i)    = vel1_avg     +  dvel1_mean     +  dvel1_d(i)     
!            vel2_bc(i)    = vel2_avg     +  dvel2_mean     +  dvel2_d(i)     
!            vel3_bc(i)    = vel3_avg     +  dvel3_mean     +  dvel3_d(i)     
!            p_bc(i)       = p_avg        +  dp_mean        +  dp_d(i)

        end do
        


        !
        ! Form conserved variables
        !
        density_bc = density_bc
        mom1_bc    = density_bc*vel1_bc
        mom2_bc    = density_bc*vel2_bc
        mom3_bc    = density_bc*vel3_bc
        energy_bc  = p_bc/(gam - ONE)  + (density_bc*HALF)*(vel1_bc*vel1_bc + vel2_bc*vel2_bc + vel3_bc*vel3_bc)


        !
        ! Account for cylindrical. Convert tangential momentum back to angular momentum.
        !
        if (worker%coordinate_system() == 'Cylindrical') then
            mom2_bc = mom2_bc * r
        end if


        !
        ! Store boundary condition state. Q_bc
        !
        call worker%store_bc_state('Density'   , density_bc, 'value')
        call worker%store_bc_state('Momentum-1', mom1_bc,    'value')
        call worker%store_bc_state('Momentum-2', mom2_bc,    'value')
        call worker%store_bc_state('Momentum-3', mom3_bc,    'value')
        call worker%store_bc_state('Energy'    , energy_bc,  'value')





    end subroutine compute_bc_state
    !*********************************************************************************






    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/14/2018
    !!
    !---------------------------------------------------------------------------------
    subroutine project_to_eigenmodes(amp_real, amp_imag, VR, VL, U_hat)
        type(AD_D),     intent(inout)   :: amp_real(:)
        type(AD_D),     intent(inout)   :: amp_imag(:)
        complex(rk),    intent(in)      :: VR(:,:)
        complex(rk),    intent(in)      :: VL(:,:)
        type(AD_D),     intent(in)      :: U_hat(:)

        type(AD_D), allocatable :: U_hat_tmp(:)
        integer :: ivec, inode

        ! Copy U_hat for modification
        U_hat_tmp = U_hat


        amp_real(:) = U_hat(1)
        amp_imag(:) = U_hat(1)
        amp_real(:) = ZERO
        amp_imag(:) = ZERO


        do ivec = 1,size(VL,2)
            do inode = 1,size(VL,1)
                amp_real(ivec) = amp_real(ivec) + realpart(VL(inode,ivec)) * U_hat_tmp(inode)
                ! Minus here due to conjugate in inner-product definition
                amp_imag(ivec) = amp_imag(ivec) - imagpart(VL(inode,ivec)) * U_hat_tmp(inode)
            end do

            ! Subtract energy from available in U_hat
            U_hat_tmp = U_hat_tmp - amp_real(ivec)*realpart(VR(:,ivec))

        end do


    end subroutine project_to_eigenmodes
    !*********************************************************************************
























end module bc_state_outlet_3dgiles_innerproduct
