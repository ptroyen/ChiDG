module bc_state_outlet_neumann_pressure_localdg_new_point
#include <messenger.h>
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: ZERO, ONE, HALF, TWO, FOUR, NFACES, ME
    use mod_fluid,              only: gam, Rgas

    use type_mesh,              only: mesh_t
    use type_face_info,         only: face_info_t
    use type_bc_state,          only: bc_state_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_properties,        only: properties_t
    use type_point,             only: point_t
    use mpi_f08,                only: mpi_comm, mpi_comm_rank
    use mod_interpolate,        only: interpolate_face_autodiff, interpolate_element_autodiff
    use mod_fgmres_standard,    only: fgmres_autodiff
    use mod_inv,                only: inv
    use ieee_arithmetic
    use DNAD_D
    implicit none


    !> 
    !!  
    !!  @author Nathan A. Wukie
    !!  @date   9/2/2018
    !!
    !----------------------------------------------------------------------------------------
    type, public, extends(bc_state_t) :: outlet_neumann_pressure_localdg_new_point_t

        real(rk),   allocatable :: dRdp(:,:,:)

    contains

        procedure   :: init                 ! Set-up bc state with options/name etc.
        procedure   :: compute_bc_state     ! boundary condition function implementation

        procedure   :: compute_local_linearization
        procedure   :: compute_local_residual
        procedure   :: converge_local_problem

    end type outlet_neumann_pressure_localdg_new_point_t
    !****************************************************************************************




contains



    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   9/2/2018
    !!
    !--------------------------------------------------------------------------------
    subroutine init(self)
        class(outlet_neumann_pressure_localdg_new_point_t),   intent(inout) :: self
        
        !
        ! Set name, family
        !
        call self%set_name("Outlet - Neumann Pressure Local DG New Point")
        call self%set_family("Outlet")

        call self%bcproperties%add('Average Pressure',         'Required')
        call self%bcproperties%add('Normal Pressure Gradient', 'Required')

    end subroutine init
    !********************************************************************************




    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   9/2/2018
    !!
    !--------------------------------------------------------------------------------
    subroutine compute_local_linearization(self,worker,bc_comm)
        class(outlet_neumann_pressure_localdg_new_point_t),   intent(inout)   :: self
        type(chidg_worker_t),                           intent(inout)   :: worker
        type(mpi_comm),                                 intent(in)      :: bc_comm

        real(rk),   allocatable, dimension(:,:) :: &
            lhs, inv_lhs, grad1, grad2, grad3, val, val1, val2, val3, &
            valtrans, grad1_trans, grad2_trans, grad3_trans, invmass, &
            temp1, temp2, temp3, face_mass1,face_mass2,face_mass3, br2_face
        real(rk),   allocatable, dimension(:)   :: weights, jinv, n1, n2, n3
        integer(ik) :: idomain_l, ielement_l, iface, nterms_s, group_ID, &
                       patch_ID, face_ID, ierr, iterm, iface_local


        ! Get location on domain
        idomain_l  = worker%element_info%idomain_l
        ielement_l = worker%element_info%ielement_l
        iface      = worker%iface
        nterms_s   = worker%mesh%domain(idomain_l)%elems(ielement_l)%nterms_s


        if (.not. worker%mesh%domain(idomain_l)%elems(ielement_l)%bc_initialized) then

            ! Get location on bc_patch_group
            group_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%group_ID
            patch_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%patch_ID
            face_ID  = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%face_ID

            allocate(lhs(nterms_s,nterms_s), stat=ierr)
            if (ierr /= 0) call AllocationError
            lhs = ZERO

            do iface_local = 1,NFACES

                ! If not boundary
                if (iface_local /= iface) then

                    ! Get mass
                    invmass = worker%mesh%domain(idomain_l)%elems(ielement_l)%invmass

                    ! Get valtrans
                    val      = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%basis_s%interpolator_face('Value',iface_local)
                    valtrans = transpose(worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%basis_s%interpolator_face('Value',iface_local)) 
                    br2_face = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%br2_face

                    ! Get grad
                    grad1 = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%grad1
                    grad2 = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%grad2
                    grad3 = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%grad3

                    ! Get normal 
                    n1 = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%norm(:,1)
                    n2 = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%norm(:,2)
                    n3 = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%norm(:,3)

                    ! Get weights
                    weights = worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_face(iface_local)

                    ! Premultiply by normal, jacobian, weights. (jacobian is in the normal)
                    do iterm = 1,size(grad1,2)
                        grad1(:,iterm) = grad1(:,iterm)*n1*weights
                        grad2(:,iterm) = grad2(:,iterm)*n2*weights
                        grad3(:,iterm) = grad3(:,iterm)*n3*weights
                    end do


                    ! Contribution from primary boundary integral: int(psi grad(sigma) dot n)dA
                    lhs = lhs + matmul(valtrans,grad1)
                    lhs = lhs + matmul(valtrans,grad2)
                    lhs = lhs + matmul(valtrans,grad3)


                    ! Contributions from lifting operators to boundary
                    val1 = ZERO*val
                    val2 = ZERO*val
                    val3 = ZERO*val
                    do iterm = 1,size(val,2)
                        val1(:,iterm) = val(:,iterm)*n1*weights
                        val2(:,iterm) = val(:,iterm)*n2*weights
                        val3(:,iterm) = val(:,iterm)*n3*weights
                    end do

                    ! Contribute to linearization
                    face_mass1 = matmul(valtrans,val1)
                    face_mass2 = matmul(valtrans,val2)
                    face_mass3 = matmul(valtrans,val3)

                    temp1 = matmul(face_mass1,invmass)
                    temp2 = matmul(face_mass2,invmass)
                    temp3 = matmul(face_mass3,invmass)

                    ! Contribution from lift boundary integral: int(psi r dot n)dA
                    lhs = lhs + matmul(temp1,-face_mass1)
                    lhs = lhs + matmul(temp2,-face_mass2)
                    lhs = lhs + matmul(temp3,-face_mass3)
                end if


                ! If not boundary
                if (iface_local /= iface) then

                    ! Get val
                    val      = worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%interpolator_element('Value')
                    valtrans = transpose(worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%interpolator_element('Value')) 
                    ! Get weights(element)
                    weights = worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_element()
                    jinv    = worker%mesh%domain(idomain_l)%elems(ielement_l)%jinv
                    ! Get grad_trans(element)
                    grad1_trans = transpose(worker%mesh%domain(idomain_l)%elems(ielement_l)%grad1)
                    grad2_trans = transpose(worker%mesh%domain(idomain_l)%elems(ielement_l)%grad2)
                    grad3_trans = transpose(worker%mesh%domain(idomain_l)%elems(ielement_l)%grad3)

                    ! Contributions from lifting operators to boundary
                    do iterm = 1,size(val,2)
                        val(:,iterm) = val(:,iterm)*jinv*weights
                    end do
                    
                    ! mat 1
                    temp1 = matmul(grad1_trans,val)
                    temp2 = matmul(grad2_trans,val)
                    temp3 = matmul(grad3_trans,val)

                    temp1 = matmul(temp1,invmass)
                    temp2 = matmul(temp2,invmass)
                    temp3 = matmul(temp3,invmass)


                    ! Get valtrans
                    val      = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%basis_s%interpolator_face('Value',iface_local)
                    valtrans = transpose(worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%basis_s%interpolator_face('Value',iface_local)) 
                    ! Get normal 
                    n1 = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%norm(:,1)
                    n2 = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%norm(:,2)
                    n3 = worker%mesh%domain(idomain_l)%faces(ielement_l,iface_local)%norm(:,3)
                    ! Get weights
                    weights = worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_face(iface_local)

                    ! Contributions from lifting operators to volume
                    val1 = ZERO*val
                    val2 = ZERO*val
                    val3 = ZERO*val
                    do iterm = 1,size(val,2)
                        val1(:,iterm) = val(:,iterm)*n1*weights
                        val2(:,iterm) = val(:,iterm)*n2*weights
                        val3(:,iterm) = val(:,iterm)*n3*weights
                    end do

                    ! Contribute to linearization
                    face_mass1 = matmul(valtrans,val1)
                    face_mass2 = matmul(valtrans,val2)
                    face_mass3 = matmul(valtrans,val3)

                    ! Contribution from lift volume integral: int(grad(psi) dot r)dV
                    lhs = lhs - matmul(temp1,-face_mass1)
                    lhs = lhs - matmul(temp2,-face_mass2)
                    lhs = lhs - matmul(temp3,-face_mass3)
                end if




            end do



            ! Get grad
            grad1 = worker%mesh%domain(idomain_l)%elems(ielement_l)%grad1
            grad2 = worker%mesh%domain(idomain_l)%elems(ielement_l)%grad2
            grad3 = worker%mesh%domain(idomain_l)%elems(ielement_l)%grad3

            ! Get grad_trans
            grad1_trans = transpose(worker%mesh%domain(idomain_l)%elems(ielement_l)%grad1)
            grad2_trans = transpose(worker%mesh%domain(idomain_l)%elems(ielement_l)%grad2)
            grad3_trans = transpose(worker%mesh%domain(idomain_l)%elems(ielement_l)%grad3)

            ! Get weights
            weights = worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_element()
            jinv    = worker%mesh%domain(idomain_l)%elems(ielement_l)%jinv

            ! Premultiply by jacobian, weights. (jacobian is in the normal)
            do iterm = 1,size(grad1,2)
                grad1(:,iterm) = grad1(:,iterm)*jinv*weights
                grad2(:,iterm) = grad2(:,iterm)*jinv*weights
                grad3(:,iterm) = grad3(:,iterm)*jinv*weights
            end do

            ! Contribution from primary volume integral: int(grad(psi) dot grad(sigma))dV
            lhs = lhs - matmul(grad1_trans,grad1)
            lhs = lhs - matmul(grad2_trans,grad2)
            lhs = lhs - matmul(grad3_trans,grad3)

            ! Invert jacobian
            inv_lhs = inv(lhs)
                    
            ! Store and register initialized
            worker%mesh%domain(idomain_l)%elems(ielement_l)%bc = inv_lhs
            worker%mesh%domain(idomain_l)%elems(ielement_l)%bc_initialized = .true.

        end if ! .not. initialized


    end subroutine compute_local_linearization
    !**********************************************************************************************






    !>  Compute routine for Pressure Outlet boundary condition state function.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   9/2/2018
    !!
    !!  @param[in]      worker  Interface for geometry, cache, integration, etc.
    !!  @param[inout]   prop    properties_t object containing equations and material_t objects
    !!
    !-----------------------------------------------------------------------------------------
    subroutine compute_bc_state(self,worker,prop,bc_COMM)
        class(outlet_neumann_pressure_localdg_new_point_t),  intent(inout)   :: self
        type(chidg_worker_t),               intent(inout)   :: worker
        class(properties_t),                intent(inout)   :: prop
        type(mpi_comm),                     intent(in)      :: bc_COMM


        ! Storage at quadrature nodes
        type(AD_D), allocatable, dimension(:)   ::                      &
            density_m,  mom1_m,  mom2_m,  mom3_m,  energy_m,            &
            density_bc, mom1_bc, mom2_bc, mom3_bc, energy_bc,           &
            grad1_density_m, grad1_mom1_m, grad1_mom2_m, grad1_mom3_m, grad1_energy_m,  &
            grad2_density_m, grad2_mom1_m, grad2_mom2_m, grad2_mom3_m, grad2_energy_m,  &
            grad3_density_m, grad3_mom1_m, grad3_mom2_m, grad3_mom3_m, grad3_energy_m,  &
            u_bc,   v_bc,    w_bc,  T_m, T_bc, p_bc, p_modes

        real(rk),   allocatable, dimension(:)   :: r
            

        ! Make sure local problem linearization is initialized
        call self%compute_local_linearization(worker,bc_comm)

        ! Converge element-local problem: p_modes
        call self%converge_local_problem(worker,bc_comm,p_modes)

        ! Compute boundary state with that from element-local problem just solved
        associate( val => worker%mesh%domain(worker%element_info%idomain_l)%faces(worker%element_info%ielement_l,worker%iface)%basis_s%interpolator_face('Value',worker%iface) )
            p_bc = matmul(val, p_modes)
        end associate


        !
        ! Interpolate interior solution to face quadrature nodes
        !
        density_m = worker%get_field('Density'    , 'value', 'face interior')
        mom1_m    = worker%get_field('Momentum-1' , 'value', 'face interior')
        mom2_m    = worker%get_field('Momentum-2' , 'value', 'face interior')
        mom3_m    = worker%get_field('Momentum-3' , 'value', 'face interior')
        energy_m  = worker%get_field('Energy'     , 'value', 'face interior')
        T_m       = worker%get_field('Temperature', 'value', 'face interior')



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


        ! Account for cylindrical. Get tangential momentum from angular momentum.
        r = worker%coordinate('1','boundary')
        if (worker%coordinate_system() == 'Cylindrical') then
            mom2_m = mom2_m / r
        end if

        ! Extrapolate temperature and velocity
        T_bc = T_m
        u_bc = mom1_m/density_m
        v_bc = mom2_m/density_m
        w_bc = mom3_m/density_m

        ! Compute density, momentum, energy
        density_bc = p_bc/(Rgas*T_bc)
        mom1_bc    = u_bc*density_bc
        mom2_bc    = v_bc*density_bc
        mom3_bc    = w_bc*density_bc
        energy_bc  = p_bc/(gam - ONE) + (density_bc*HALF)*(u_bc*u_bc + v_bc*v_bc + w_bc*w_bc)

        ! Account for cylindrical. Convert tangential momentum back to angular momentum.
        if (worker%coordinate_system() == 'Cylindrical') then
            mom2_bc = mom2_bc * r
        end if

        ! Store boundary condition state
        call worker%store_bc_state('Density'   , density_bc, 'value')
        call worker%store_bc_state('Momentum-1', mom1_bc,    'value')
        call worker%store_bc_state('Momentum-2', mom2_bc,    'value')
        call worker%store_bc_state('Momentum-3', mom3_bc,    'value')
        call worker%store_bc_state('Energy'    , energy_bc,  'value')


        ! Store boundary condition gradient
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


    end subroutine compute_bc_state
    !**************************************************************************************




    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   9/2/2018
    !!
    !------------------------------------------------------------------------------
    subroutine compute_pressure_gradient(worker,grad1_p, grad2_p, grad3_p) 
        type(chidg_worker_t),                   intent(inout)   :: worker
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad1_p 
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad2_p 
        type(AD_D), allocatable, dimension(:),  intent(inout)   :: grad3_p 

        type(AD_D), allocatable, dimension(:)   ::                              &
            density,       mom1,       mom2,       mom3,       energy,          &
            grad1_density, grad1_mom1, grad1_mom2, grad1_mom3, grad1_energy,    &
            grad2_density, grad2_mom1, grad2_mom2, grad2_mom3, grad2_energy,    &
            grad3_density, grad3_mom1, grad3_mom2, grad3_mom3, grad3_energy,    &
            dp_ddensity, dp_dmom1, dp_dmom2, dp_dmom3, dp_denergy

        real(rk),   allocatable, dimension(:)   :: r


        !
        ! Interpolate solution to quadrature nodes
        !
        density       = worker%get_field('Density',    'value')
        mom1          = worker%get_field('Momentum-1', 'value')
        mom2          = worker%get_field('Momentum-2', 'value')
        mom3          = worker%get_field('Momentum-3', 'value')
        energy        = worker%get_field('Energy',     'value')


        if (worker%interpolation_source == 'element') then

            grad1_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad1')
            grad1_mom1    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 2, worker%itime, 'grad1')
            grad1_mom2    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 3, worker%itime, 'grad1')
            grad1_mom3    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 4, worker%itime, 'grad1')
            grad1_energy  = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 5, worker%itime, 'grad1')

            grad2_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad2')
            grad2_mom1    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 2, worker%itime, 'grad2')
            grad2_mom2    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 3, worker%itime, 'grad2')
            grad2_mom3    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 4, worker%itime, 'grad2')
            grad2_energy  = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 5, worker%itime, 'grad2')

            grad3_density = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 1, worker%itime, 'grad3')
            grad3_mom1    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 2, worker%itime, 'grad3')
            grad3_mom2    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 3, worker%itime, 'grad3')
            grad3_mom3    = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 4, worker%itime, 'grad3')
            grad3_energy  = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info, 5, worker%itime, 'grad3')


        else

            grad1_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 1, worker%itime, 'grad1', ME)
            grad1_mom1    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 2, worker%itime, 'grad1', ME)
            grad1_mom2    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 3, worker%itime, 'grad1', ME)
            grad1_mom3    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 4, worker%itime, 'grad1', ME)
            grad1_energy  = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 5, worker%itime, 'grad1', ME)

            grad2_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 1, worker%itime, 'grad2', ME)
            grad2_mom1    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 2, worker%itime, 'grad2', ME)
            grad2_mom2    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 3, worker%itime, 'grad2', ME)
            grad2_mom3    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 4, worker%itime, 'grad2', ME)
            grad2_energy  = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 5, worker%itime, 'grad2', ME)

            grad3_density = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 1, worker%itime, 'grad3', ME)
            grad3_mom1    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 2, worker%itime, 'grad3', ME)
            grad3_mom2    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 3, worker%itime, 'grad3', ME)
            grad3_mom3    = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 4, worker%itime, 'grad3', ME)
            grad3_energy  = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info, 5, worker%itime, 'grad3', ME)

        end if




        !
        ! Account for cylindrical. Get tangential momentum from angular momentum.
        ! Also convert derivatives from derivatives of angular momentum to tangential.
        !
        ! We want:
        !       (rho * u_theta)  instead of      (r * rho * u_theta)
        !   grad(rho * u_theta)  instead of  grad(r * rho * u_theta)
        !
        !   grad(rho * u_theta) = grad(r * rho * u_theta)/r  -  grad(r)(rho*u_theta)/r
        !
        ! Where grad(r) = [1,0,0]
        !
        if (worker%coordinate_system() == 'Cylindrical') then
            r = worker%coordinate('1')
            mom2       = mom2 / r
            grad1_mom2 = (grad1_mom2/r) - mom2/r
            grad2_mom2 = (grad2_mom2/r)
            grad3_mom2 = (grad3_mom2/r)
        end if

        ! Compute pressure jacobians
        dp_ddensity =  (gam-ONE)*HALF*(mom1*mom1 + mom2*mom2 + mom3*mom3)/(density*density)
        dp_dmom1    = -(gam-ONE)*mom1/density
        dp_dmom2    = -(gam-ONE)*mom2/density
        dp_dmom3    = -(gam-ONE)*mom3/density
        dp_denergy  = dp_ddensity ! init storage
        dp_denergy  =  (gam-ONE)

        ! Compute pressure gradient
        grad1_p = dp_ddensity * grad1_density  + &
                  dp_dmom1    * grad1_mom1     + &
                  dp_dmom2    * grad1_mom2     + &
                  dp_dmom3    * grad1_mom3     + &
                  dp_denergy  * grad1_energy

        grad2_p = dp_ddensity * grad2_density  + &
                  dp_dmom1    * grad2_mom1     + &
                  dp_dmom2    * grad2_mom2     + &
                  dp_dmom3    * grad2_mom3     + &
                  dp_denergy  * grad2_energy

        grad3_p = dp_ddensity * grad3_density  + &
                  dp_dmom1    * grad3_mom1     + &
                  dp_dmom2    * grad3_mom2     + &
                  dp_dmom3    * grad3_mom3     + &
                  dp_denergy  * grad3_energy


    end subroutine compute_pressure_gradient
    !******************************************************************************





    !>
    !!
    !!  @author Nathan A. Wukie
    !!  @date   9/2/2018
    !!
    !------------------------------------------------------------------------------
    function compute_local_residual(self,worker,bc_comm,p_modes) result(R_modes)
        class(outlet_neumann_pressure_localdg_new_point_t), intent(inout)               :: self
        type(chidg_worker_t),                               intent(inout)               :: worker
        type(mpi_comm),                                     intent(in)                  :: bc_comm
        type(AD_D),                                         intent(inout), allocatable  :: p_modes(:)

        type(AD_D), allocatable, dimension(:)   ::                          &
            p_sigma,        grad1_sigma,    grad2_sigma,    grad3_sigma,    &
            p, grad1_p,     grad2_p,        grad3_p,                        &
            lift_face_1,    lift_face_2,    lift_face_3,                    &
            lift_elem_1,    lift_elem_2,    lift_elem_3,                    &
            diff_1,         diff_2,         diff_3,     diff,               &
            face_array, element_array, R_modes, integral, integrand, flux1, flux2, flux3, p_m

        integer(ik) :: iface, iface_bc, idomain_l, ielement_l, bc_IRANK, ierr, group_ID, patch_ID, face_ID
        logical :: enforce_value

        real(rk),   allocatable, dimension(:) :: p_avg_user, gradn_p_user, grad1_p_user, grad2_p_user, grad3_p_user
        real(rk)    :: stabilization

        type(AD_D)  :: delta_p, p_m_avg


        !
        ! Get user parameter settings
        !
        p_avg_user   = self%bcproperties%compute('Average Pressure',         worker%time(),worker%coords())
        gradn_p_user = self%bcproperties%compute('Normal Pressure Gradient', worker%time(),worker%coords())
        grad1_p_user = gradn_p_user*worker%unit_normal(1)
        grad2_p_user = gradn_p_user*worker%unit_normal(2)
        grad3_p_user = gradn_p_user*worker%unit_normal(3)


        ! Check if current face contains point
        p_m = worker%get_field('Pressure','value','face interior')
        p_m_avg = sum(p_m)/real(size(p_m),rk)


        !
        ! Get bc_NRANK, bc_IRANK from bc_COMM
        !
        call MPI_Comm_Rank(bc_comm, bc_IRANK, ierr)
        
        ! Get location on domain
        idomain_l  = worker%element_info%idomain_l
        ielement_l = worker%element_info%ielement_l
        iface      = worker%iface

        ! Get location on bc_patch_group
        group_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%group_ID
        patch_ID = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%patch_ID
        face_ID  = worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%face_ID

        enforce_value = (bc_IRANK == 0) .and.  (patch_ID == 1) .and. (face_ID == 1)

        if (enforce_value) then
            delta_p = p_avg_user(1) - p_m_avg
        else 
            delta_p = ZERO*p_m_avg
        end if
        print*, 'Delta p: ', delta_p%x_ad_
        print*, 'Element info: ', worker%element_info%idomain_g, worker%element_info%ielement_g



        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Store index of bc face
        iface_bc = worker%iface

        ! Initialize face/element array sizes
        face_array    = worker%get_field('Pressure','value','face interior')
        element_array = worker%get_field('Pressure','value','element')
        face_array    = ZERO
        element_array = ZERO

        ! Initialize R_modes storage
        R_modes = p_modes
        R_modes = ZERO

        ! Initialize p at quadrature nodes to zero
        lift_elem_1 = element_array
        lift_elem_2 = element_array
        lift_elem_3 = element_array

        ! Accumulate FACE residuals
        do iface = 1,NFACES

            lift_face_1 = face_array
            lift_face_2 = face_array
            lift_face_3 = face_array

            worker%iface = iface
            worker%interpolation_source = 'face interior'

            ! Get sigma
            p_sigma = worker%get_field('Pressure','value','face interior')
            call compute_pressure_gradient(worker,grad1_sigma,grad2_sigma,grad3_sigma)


            associate ( weights  => worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_face(iface),                        &
                        br2_face => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_face,                                     &
                        br2_vol  => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%br2_vol,                                      &
                        val      => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%basis_s%interpolator_face('Value',iface),     &
                        grad1    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad1,                                        &
                        grad2    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad2,                                        &
                        grad3    => worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%grad3,                                        &
                        valtrans => transpose(worker%mesh%domain(idomain_l)%faces(ielement_l,iface)%basis_s%interpolator_face('Value',iface)) )


            ! INTERIOR FACE
            if (iface /= iface_bc) then

                ! Take boundary state from interior original problem
                p       = matmul(val, p_modes)
                grad1_p = matmul(grad1,p_modes)
                grad2_p = matmul(grad2,p_modes)
                grad3_p = matmul(grad3,p_modes)

                diff = (p_sigma - p)

            ! BOUNDARY FACE
            else

                ! boundary pressure: extrapolating interior and adding average update.
                ! boundary pressure gradient: set to user-specified values
                p   = matmul(val, p_modes)
                p   = p + delta_p
                
                grad1_p = face_array
                grad2_p = face_array
                grad3_p = face_array
                grad1_p = grad1_p_user
                grad2_p = grad2_p_user
                grad3_p = grad3_p_user

                diff = (p_sigma - p)
                diff = 4000.*delta_p
                !diff = delta_p

            end if


            ! Multiply by normal. Note: normal is scaled by face jacobian.
            diff_1 = diff * weights * worker%normal(1)
            diff_2 = diff * weights * worker%normal(2)
            diff_3 = diff * weights * worker%normal(3)


            ! Compute lift at face gq nodes
            lift_face_1 = matmul(br2_face,diff_1)
            lift_face_2 = matmul(br2_face,diff_2)
            lift_face_3 = matmul(br2_face,diff_3)
        

            ! Accumulate face lift to element gq nodes
            lift_elem_1 = lift_elem_1 + matmul(br2_vol,diff_1)
            lift_elem_2 = lift_elem_2 + matmul(br2_vol,diff_2)
            lift_elem_3 = lift_elem_3 + matmul(br2_vol,diff_3)


            ! Penalize gradient with lift
            stabilization = 1.0_rk
            grad1_p = grad1_p  +  stabilization*lift_face_1
            grad2_p = grad2_p  +  stabilization*lift_face_2
            grad3_p = grad3_p  +  stabilization*lift_face_3

            integrand = weights*( (grad1_p-grad1_sigma)*worker%normal(1) +  &
                                  (grad2_p-grad2_sigma)*worker%normal(2) +  &
                                  (grad3_p-grad3_sigma)*worker%normal(3) )

            integral = matmul(valtrans,integrand)

            ! Accumulate residual from face
            R_modes = R_modes  +  integral

            end associate
        end do

        associate ( weights     => worker%mesh%domain(idomain_l)%elems(ielement_l)%basis_s%weights_element(),               &
                    jinv        => worker%mesh%domain(idomain_l)%elems(ielement_l)%jinv,                                    & 
                    grad1       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad1,                                   &
                    grad2       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad2,                                   &
                    grad3       => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad3,                                   &
                    grad1_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad1_trans,                             &
                    grad2_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad2_trans,                             &
                    grad3_trans => worker%mesh%domain(idomain_l)%elems(ielement_l)%grad3_trans )

        ! Accumulate ELEMENT residuals
        worker%iface = 1
        worker%interpolation_source = 'element'

        ! Get sigma
        call compute_pressure_gradient(worker,grad1_sigma,grad2_sigma,grad3_sigma)

        ! Get grad_p
        grad1_p = matmul(grad1, p_modes)
        grad2_p = matmul(grad2, p_modes)
        grad3_p = matmul(grad3, p_modes)

        ! Penalize grad_p with boundary lift
        grad1_p = grad1_p + lift_elem_1
        grad2_p = grad2_p + lift_elem_2
        grad3_p = grad3_p + lift_elem_3

        flux1 = (grad1_p - grad1_sigma)*weights*jinv
        flux2 = (grad2_p - grad2_sigma)*weights*jinv
        flux3 = (grad3_p - grad3_sigma)*weights*jinv

        integral = matmul(grad1_trans, flux1) + &
                   matmul(grad2_trans, flux2) + &
                   matmul(grad3_trans, flux3) 


        R_modes = R_modes - integral

        end associate

        ! Reset iface_bc
        call worker%set_face(iface_bc)


    end function compute_local_residual
    !******************************************************************************





    !>  Newton solver
    !!
    !!  @author Nathan A. Wukie
    !!  @date   9/2/2018
    !!
    !------------------------------------------------------------------------------
    subroutine converge_local_problem(self,worker,bc_comm,p_modes)
        class(outlet_neumann_pressure_localdg_new_point_t),   intent(inout)               :: self
        type(chidg_worker_t),                           intent(inout)               :: worker
        type(mpi_comm),                                 intent(in)                  :: bc_comm
        type(AD_D),                                     intent(inout), allocatable  :: p_modes(:)

        type(AD_D), allocatable, dimension(:)   ::  &
            R_modes, zero_face, R_modes_i, R_modes_p, p_modes_perturb, dp, tmp


        real(rk),   allocatable, dimension(:,:) :: dRdp, inv_dRdp
        real(rk)    :: tol, resid
        integer(ik) :: nterms_s, idomain_l, ielement_l, ierr

        ! Get element location
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 

        ! Initialize emptry array with derivatives allocated
        zero_face = worker%get_field('Density','value','face interior')
        zero_face = ZERO

        ! Initialize p_modes storage with derivatives
        nterms_s = worker%mesh%domain(idomain_l)%elems(ielement_l)%nterms_s
        allocate(p_modes(nterms_s), stat=ierr)
        if (ierr /= 0) call AllocationError
        p_modes(:) = zero_face(1)
        if (size(p_modes) /= nterms_s) call chidg_signal(FATAL,'outlet_neumann_pressure_localdg_new_point: converge_p Error 1.')


        resid = huge(1._rk)
        tol = 1.e-3_rk
        R_modes = self%compute_local_residual(worker,bc_comm,p_modes)
        do while (resid > tol)

            ! Move R to right-hand side
            R_modes = (-ONE)*R_modes

            ! Solve linear system: bc was precomputed from init_bc_local_problem
            dp = matmul(worker%mesh%domain(idomain_l)%elems(ielement_l)%bc,R_modes)

            ! Apply update
            p_modes = p_modes + dp

            ! Test residual
            R_modes = self%compute_local_residual(worker,bc_comm,p_modes)
            resid = norm2(R_modes(:)%x_ad_)

            if (resid > 1.e10_rk) call chidg_signal(FATAL,"outlet_neumann_pressure_localdg_new_point: element-local problem diverged.")

        end do


    end subroutine converge_local_problem
    !******************************************************************************









end module bc_state_outlet_neumann_pressure_localdg_new_point
