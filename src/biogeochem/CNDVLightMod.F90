module CNDVLightMod

  !-----------------------------------------------------------------------
  ! !DESCRIPTION:
  ! Calculate light competition
  ! Update fpc for establishment routine
  ! Called once per year
  !
  ! !USES:
  use shr_kind_mod         , only: r8 => shr_kind_r8
  use shr_const_mod        , only : SHR_CONST_PI
  use decompMod            , only : bounds_type
  use pftconMod            , only : pftcon
  use CNDVType             , only : dgv_ecophyscon, dgvs_type
  use CNVegCarbonStateType , only : cnveg_carbonstate_type
  use PatchType            , only : patch                
  !
  ! !PUBLIC TYPES:
  implicit none
  !
  ! !PUBLIC MEMBER FUNCTIONS:
  public :: Light
  !-----------------------------------------------------------------------

contains

  !-----------------------------------------------------------------------
  subroutine Light(bounds, num_natvegp, filter_natvegp, &
       cnveg_carbonstate_inst, dgvs_inst)
    !
    ! !DESCRIPTION:
    ! Calculate light competition and update fpc for establishment routine
    ! Called once per year
    !
    ! !ARGUMENTS:
    type(bounds_type)            , intent(in)    :: bounds                  
    integer                      , intent(in)    :: num_natvegp             ! number of naturally-vegetated patches in filter
    integer                      , intent(in)    :: filter_natvegp(:)       ! patch filter for naturally-vegetated points
    type(cnveg_carbonstate_type) , intent(in)    :: cnveg_carbonstate_inst
    type(dgvs_type)              , intent(inout) :: dgvs_inst
    !
    ! !LOCAL VARIABLES:
    real(r8), parameter :: fpc_tree_max = 0.95_r8 !maximum total tree FPC
    integer  :: p,fp, g                           ! indices
    real(r8) :: fpc_tree_total(bounds%begg:bounds%endg)
    real(r8) :: fpc_inc_tree(bounds%begg:bounds%endg)
    real(r8) :: fpc_inc(bounds%begp:bounds%endp)  ! foliar projective cover increment (fraction)
    real(r8) :: fpc_grass_total(bounds%begg:bounds%endg)
    real(r8) :: fpc_shrub_total(bounds%begg:bounds%endg)
    real(r8) :: fpc_grass_max(bounds%begg:bounds%endg)
    real(r8) :: fpc_shrub_max(bounds%begg:bounds%endg)
    integer  :: numtrees(bounds%begg:bounds%endg)
    real(r8) :: excess
    real(r8) :: nind_kill
    real(r8) :: lai_ind
    real(r8) :: fpc_ind
    real(r8) :: fpcgrid_old
    real(r8) :: lm_ind   ! leaf carbon (gC/individual)
    real(r8) :: stemdiam ! stem diameter
    real(r8) :: stocking ! #stems / ha (stocking density)
    real(r8) :: taper    ! ratio of height:radius_breast_height (tree allometry)
    !-----------------------------------------------------------------------

    associate(                                                        & 
         ivt           =>    patch%itype                              , & ! Input:  [integer  (:) ]  patch vegetation type                                
         
         crownarea_max =>    dgv_ecophyscon%crownarea_max           , & ! Input:  [real(r8) (:) ]  ecophys const - tree maximum crown a              
         reinickerp    =>    dgv_ecophyscon%reinickerp              , & ! Input:  [real(r8) (:) ]  ecophys const - parameter in allomet              
         allom1        =>    dgv_ecophyscon%allom1                  , & ! Input:  [real(r8) (:) ]  ecophys const - parameter in allomet              

         dwood         =>    pftcon%dwood                           , & ! Input:  wood density (gC/m3)              
         slatop        =>    pftcon%slatop                          , & ! Input:  specific leaf area at top of canopy, projected area basis (m2/gC)
         dsladlai      =>    pftcon%dsladlai                        , & ! Input:  dSLA/dLAI, projected area basis (m2/gC)           
         woody         =>    pftcon%woody                           , & ! Input:  woody patch or not                  
         tree          =>    pftcon%tree                            , & ! Input:  tree patch or not                    
         
         deadstemc     =>    cnveg_carbonstate_inst%deadstemc_patch , & ! Input:  [real(r8) (:) ]  (gC/m2) dead stem C                               
         leafcmax      =>    cnveg_carbonstate_inst%leafcmax_patch  , & ! Input:  [real(r8) (:) ]  (gC/m2) leaf C storage                            

         crownarea     =>    dgvs_inst%crownarea_patch              , & ! Output: [real(r8) (:) ]  area that each individual tree takes up (m^2)     
         nind          =>    dgvs_inst%nind_patch                   , & ! Output: [real(r8) (:) ]  number of individuals                             
         fpcgrid       =>    dgvs_inst%fpcgrid_patch                  & ! Output: [real(r8) (:) ]  foliar projective cover on gridcell (fraction)    
         )

      taper = 200._r8 ! make a global constant; used in Establishment + ?

      ! Initialize gridcell-level metrics

      do g = bounds%begg, bounds%endg
         fpc_tree_total(g)  = 0._r8
         fpc_inc_tree(g)    = 0._r8
         fpc_grass_total(g) = 0._r8
         fpc_shrub_total(g) = 0._r8
         numtrees(g)        = 0
      end do

      do fp = 1,num_natvegp
         p = filter_natvegp(fp)
         g = patch%gridcell(p)

         ! Update LAI and FPC as in the last lines of DGVMAllocation

         if (woody(ivt(p))==1._r8) then
            if (fpcgrid(p) > 0._r8 .and. nind(p) > 0._r8) then
               stocking = nind(p)/fpcgrid(p) !#ind/m2 nat veg area -> #ind/m2 patch area
               ! stemdiam derived here from cn's formula for htop found in
               ! CNVegStructUpdate and cn's assumption stemdiam=2*htop/taper
               ! this derivation neglects upper htop limit enforced elsewhere
               stemdiam = (24._r8 * deadstemc(p) / (SHR_CONST_PI * stocking * dwood(ivt(p)) * taper))**(1._r8/3._r8)
            else
               stemdiam = 0._r8
            end if
            crownarea(p) = min(crownarea_max(ivt(p)), allom1(ivt(p))*stemdiam**reinickerp(ivt(p))) ! Eqn D (from Establishment)
            !else ! crownarea is 1 and does not need updating
         end if

         if (crownarea(p) > 0._r8 .and. nind(p) > 0._r8) then
            lm_ind  = leafcmax(p) * fpcgrid(p) / nind(p)
            if (dsladlai(ivt(p)) > 0._r8) then
               lai_ind = max(0.001_r8,((exp(lm_ind*dsladlai(ivt(p)) + log(slatop(ivt(p)))) - &
                    slatop(ivt(p)))/dsladlai(ivt(p))) / crownarea(p))
            else
               lai_ind = lm_ind * slatop(ivt(p)) / crownarea(p)
            end if
         else
            lai_ind = 0._r8
         end if

         fpc_ind = 1._r8 - exp(-0.5_r8*lai_ind)
         fpcgrid_old = fpcgrid(p)
         fpcgrid(p) = crownarea(p) * nind(p) * fpc_ind
         fpc_inc(p) = max(0._r8, fpcgrid(p) - fpcgrid_old)

         if (woody(ivt(p)) == 1._r8) then
            if (tree(ivt(p)) == 1) then
               numtrees(g) = numtrees(g) + 1
               fpc_tree_total(g) = fpc_tree_total(g) + fpcgrid(p)
               fpc_inc_tree(g) = fpc_inc_tree(g) + fpc_inc(p)
            else ! if shrubs
               fpc_shrub_total(g) = fpc_shrub_total(g) + fpcgrid(p)
            end if
         else    ! if grass
            fpc_grass_total(g) = fpc_grass_total(g) + fpcgrid(p)
         end if
      end do

      do g = bounds%begg, bounds%endg
         fpc_grass_max(g) = 1._r8 - min(fpc_tree_total(g), fpc_tree_max)
         fpc_shrub_max(g) = max(0._r8, fpc_grass_max(g) - fpc_grass_total(g))
      end do

      ! The gridcell level metrics are now in place; continue...
      ! slevis replaced the previous code that updated pfpcgrid
      ! with a simpler way of doing so:
      ! fpcgrid(p) = fpcgrid(p) - excess
      ! Later we may wish to update this subroutine
      ! according to Strassmann's recommendations (see relevant pdf)

      do fp = 1,num_natvegp
         p = filter_natvegp(fp)
         g = patch%gridcell(p)

         ! light competition

         if (woody(ivt(p))==1._r8 .and. tree(ivt(p))==1._r8) then

            if (fpc_tree_total(g) > fpc_tree_max) then

               if (fpc_inc_tree(g) > 0._r8) then
                  excess = (fpc_tree_total(g) - fpc_tree_max) * &
                       fpc_inc(p) / fpc_inc_tree(g)
               else
                  excess = (fpc_tree_total(g) - fpc_tree_max) / &
                       real(numtrees(g))
               end if

               ! Reduce individual density (and thereby gridcell-level biomass)
               ! so that total tree FPC reduced to 'fpc_tree_max'

               if (fpcgrid(p) > 0._r8) then
                  nind_kill = nind(p) * excess / fpcgrid(p)
                  nind(p) = max(0._r8, nind(p) - nind_kill)
                  fpcgrid(p) = max(0._r8, fpcgrid(p) - excess)
               else
                  nind(p) = 0._r8
                  fpcgrid(p) = 0._r8
               end if

               ! Transfer lost biomass to litter

            end if ! if tree cover exceeds max allowed
         else if (woody(ivt(p))==0._r8) then ! grass

            if (fpc_grass_total(g) > fpc_grass_max(g)) then

               ! grass competes with itself if total fpc exceeds 1

               excess = (fpc_grass_total(g) - fpc_grass_max(g)) * fpcgrid(p) / fpc_grass_total(g)
               fpcgrid(p) = max(0._r8, fpcgrid(p) - excess)

            end if

         else if (woody(ivt(p))==1._r8 .and. tree(ivt(p))==0._r8) then ! shrub

            if (fpc_shrub_total(g) > fpc_shrub_max(g)) then

               excess = 1._r8 - fpc_shrub_max(g) / fpc_shrub_total(g)

               ! Reduce individual density (and thereby gridcell-level biomass)
               ! so that total shrub FPC reduced to fpc_shrub_max(g)

               if (fpcgrid(p) > 0._r8) then
                  nind_kill = nind(p) * excess / fpcgrid(p)
                  nind(p) = max(0._r8, nind(p) - nind_kill)
                  fpcgrid(p) = max(0._r8, fpcgrid(p) - excess)
               else
                  nind(p) = 0._r8
                  fpcgrid(p) = 0._r8
               end if

            end if

         end if   ! end of if-tree

      end do

    end associate

  end subroutine Light

end module CNDVLightMod
