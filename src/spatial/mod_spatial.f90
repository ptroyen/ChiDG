module mod_spatial
    use mod_kinds,      only: rk,ik
    use mod_constants,  only: NFACES, DIAG
    use type_domain,    only: domain_t

    implicit none


contains

    subroutine update_space(domain,info)
        type(domain_t), intent(inout)   :: domain
        integer(ik), optional           :: info

        integer(ik) :: iblk, ielem, iface, nelem, i, ibc
        real(rk)    :: istart, istop, elapsed
        logical     :: skip = .false.


        associate ( mesh => domain%mesh, sdata => domain%sdata, eqnset => domain%eqnset)

            nelem = mesh%nelem
            !------------------------------------------------------------------------------------------
            !                                      Interior Scheme
            !------------------------------------------------------------------------------------------

            !> Loop through given element and neighbors and compute the corresponding linearization
            !> XI_MIN, XI_MAX, ETA_MIN, ETA_MAX, ZETA_MIN, ZETA_MAX, DIAG
            call cpu_time(istart)

            do iblk = 1,7

                !> Loop through elements in the domain
                do ielem = 1,nelem


                    !> If the block direction is DIAG, then we want to compute all valid faces with neighbors.
                    !! If the block direction is not DIAG, then we only want to compute faces in the block direction
                    !! if it has a neighbor element.
                    if (iblk /= DIAG) then
                        !> Check if there is an element to linearize against in the iblk direction. If not, cycle
                        if (domain%mesh%faces(ielem,iblk)%ineighbor == 0) then
                            skip = .true.
                        else
                            skip = .false.
                        end if
                    else
                        skip = .false.  !> Don't skip DIAG
                    end if




                    !-----------------------------------------------------------------------------------------
                    if ( .not. skip) then
                        ! For the current element, compute the contributions from boundary integrals
                        do iface = 1,NFACES
                            !> Only call the following routines for interior faces -- ftype == 0
                            !! Furthermore, only call the routines if we are computing derivatives for the neighbor of
                            !! iface or for the current element(DIAG). This saves a lot of unnecessary compute_boundary calls.
                            if (domain%mesh%faces(ielem,iface)%ftype == 0 .and. &
                                (iblk == iface .or. iblk == DIAG)) then
                                call domain%eqnset%compute_boundary_average_flux(mesh,sdata,ielem,iface,iblk)
                                call domain%eqnset%compute_boundary_upwind_flux( mesh,sdata,ielem,iface,iblk)
                            end if
                        end do !face



                        ! For the current element, compute the contributions from volume integrals
                        call domain%eqnset%compute_volume_flux(  mesh,sdata,ielem,iblk)
                        call domain%eqnset%compute_volume_source(mesh,sdata,ielem,iblk)

                    end if
                    !-----------------------------------------------------------------------------------------

                end do !elem

            end do !block




            !------------------------------------------------------------------------------------------
            !                                      Boundary Scheme
            !------------------------------------------------------------------------------------------
            !> For boundary conditions, the linearization only depends on Q-, which is the solution vector
            !! for the interior element. So, we only need to compute derivatives for the interior element (DIAG)
            iblk = 7    !> DIAG
!            call domain%bcset%apply(eqnset,mesh,sdata,iblk)








            call cpu_time(istop)

            elapsed = istop - istart
            print*, 'Update space: ', elapsed

        end associate

    end subroutine



end module mod_spatial
