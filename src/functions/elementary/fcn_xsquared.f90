module fcn_xsquared
    use mod_kinds,      only: rk,ik
    use type_function,  only: function_t
    use type_point,     only: point_t
    implicit none
    private



    !>  x-squared function.
    !!
    !!  \f$     f(t,\vec{x}) = x^2  \f$
    !!
    !!  @author Nathan A. Wukie
    !!  @date   2/1/2016
    !!
    !-------------------------------------------------------------------------
    type, extends(function_t), public :: xsquared_f

    contains

        procedure   :: order
        procedure   :: calc

    end type xsquared_f
    !**************************************************************************



contains


    function order(self)
        class(xsquared_f), intent(in)  :: self
        integer(ik)                 :: order

        order = 3

    end function



    elemental function calc(self,pt)
        class(xsquared_f),  intent(in)  :: self
        type(point_t),      intent(in)  :: pt
        real(rk)                        :: calc

        ! f(x) = x**2
        calc = pt%c1_  *  pt%c1_

    end function


end module fcn_xsquared
