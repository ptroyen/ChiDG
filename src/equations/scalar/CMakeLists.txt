add_subdirectory(scalar_advection)
add_subdirectory(scalar_diffusion)
#add_subdirectory(scalar_advection_ale)
#add_subdirectory(scalar_diffusion_ale)
add_subdirectory(bc)




add_lib_sources(eqn_scalar_advection.f90
                eqn_scalar_diffusion.f90
                eqn_scalar_advection_diffusion.f90
                #eqn_scalar_advection_ale.f90
                #eqn_scalar_advection_diffusion_ale.f90
                )
