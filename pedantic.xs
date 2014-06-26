#define PERL_NO_GET_CONTEXT 1
#include "EXTERN.h"
#include "perl.h"

#ifdef WIN32
# include "XSUB.h"
#else /* not WIN32 */
# define PERL_CORE
# include "XSUB.h"
# undef PERL_CORE
#endif

#ifndef CvPROTO
# define CvPROTO(cv) SvPVX((SV*)(cv))
# define CvPROTOLEN(cv) SvCUR((SV*)(cv))
#endif /* !CvPROTO */

#define WP_HAS_PERL(R, V, S) (PERL_REVISION > (R) || (PERL_REVISION == (R) && (PERL_VERSION > (V) || (PERL_VERSION == (V) && (PERL_SUBVERSION >= (S))))))

#define WP_HAS_RPEEP WP_HAS_PERL(5, 13, 5)
#if WP_HAS_RPEEP
#  define WP_PEEP PL_rpeepp
#else
#  define WP_PEEP PL_peepp
#endif

#ifndef PERL_ARGS_ASSERT_CK_WARNER
static void Perl_ck_warner(pTHX_ U32 err, const char* pat, ...);
 
#  ifdef vwarner
static
void
Perl_ck_warner(pTHX_ U32 err, const char* pat, ...)
{
  va_list args;
 
  PERL_UNUSED_ARG(err);
  if (ckWARN(err)) {
    va_list args;
    va_start(args, pat);
    vwarner(err, pat, &args);
    va_end(args);
  }
}
#  else
/* yes this replicates my_warner */
static
void
Perl_ck_warner(pTHX_ U32 err, const char* pat, ...)
{
  SV *sv;
  va_list args;
 
  PERL_UNUSED_ARG(err);
 
  va_start(args, pat);
  sv = vnewSVpvf(pat, &args);
  va_end(args);
  sv_2mortal(sv);
  warn("%s", SvPV_nolen(sv));
}
#  endif
#endif

static bool
THX_warn_for(pTHX_ U32 category, U32 category2)
#define warn_for(c,c2) THX_warn_for(aTHX_ c,c2)
{
    return !(PL_dowarn & G_WARN_ALL_OFF)
            && ( (PL_dowarn & G_WARN_ALL_ON)
                    || PL_curcop->cop_warnings == pWARN_ALL
                    || (ckWARN(category) && ckWARN(category2) )
                    || ckWARN(category2) );
}
 
static U32 pedantic       = 0;
static U32 void_grep      = 0;
static U32 void_close     = 0;
static U32 void_print     = 0;
static U32 sort_prototype = 0;

#define warnif3(x, m, a, b)    Perl_ck_warner(aTHX_ packWARN2(pedantic, x), m, a, b);
#define warnif(x,m)    warnif3(x, m, NULL, NULL)
#define warnif2(x,m, a)    warnif3(x, m, a, NULL)

static peep_t prev_rpeepp = NULL;
STATIC void
my_rpeep(pTHX_ OP *o)
#define my_rpeep(o) my_rpeep(aTHX_ o)
{
    OP *orig_o = o;
    OP *nextstate = NULL;

    for(; o; o = o->op_next) {
        char *what = NULL;
        if ( o->op_opt ) {
            PL_curcop = &PL_compiling;
            prev_rpeepp(aTHX_ orig_o);
            return;
        }
        switch(o->op_type) {
        	case OP_ENTERLOOP:
	        case OP_ENTERITER:
	            /* XXX TODO */
	            o = cLOOPo->op_lastop;
	            break;
            case OP_NULL:
                if (   o->op_targ != OP_NEXTSTATE
                    || o->op_targ != OP_DBSTATE )
                    break;
            case OP_DBSTATE:
            case OP_NEXTSTATE: {
                nextstate = o;
                PL_curcop = (COP*)(nextstate);
                break;
            }
            case OP_GREPWHILE: {
                U8 want = o->op_flags & OPf_WANT;
                if ((o->op_private & (OPpLVAL_INTRO|OPpOUR_INTRO)) || o->op_opt)
                    break;
                
                if ( want != OPf_WANT_VOID )
                    break;
                
                if (warn_for(pedantic, void_grep)) {
                    warnif(void_grep,
                        "Unusual use of grep in void context");
                }
                break;
            }
            case OP_CLOSEDIR:
                if (!what) {
                    what = "closedir";
                }
            case OP_CLOSE: {
                U8 want = o->op_flags & OPf_WANT;
                if (!what) {
                    what = "close";
                }
                if (o->op_opt || want != OPf_WANT_VOID)
                    break;
                
                if (warn_for(pedantic, void_close)) {
                    warnif2(void_close,
                        "Unusual use of %s() in void context", what);
                }
                
                break;
            }
            case OP_SAY:
                if (!what)
                    what = "say";
            case OP_PRTF:
                if (!what)
                    what = "printf";
            case OP_PRINT: {
                U8 want = o->op_flags & OPf_WANT;
                if (o->op_opt || want != OPf_WANT_VOID) {
                    what = NULL;
                    break;
                }

                if (!what)
                    what = "print";
                
                if (warn_for(pedantic, void_print)) {
                    warnif2(void_print,
                        "Suspect use of %s() in void context", what);
                }
                
                what = NULL;
                break;
            }
            case OP_SORT: {
                HV *curstash = PL_curstash;
                GV *gv;
                CV *cv;
                SV *sv;
                STRLEN protolen;
                const char * proto;
                OP * constop = NULL;
                OP * first = cUNOPx(o)->op_first->op_sibling;
                
                if (!warn_for(pedantic, sort_prototype))
                    break;
                
                if ( first->op_type == OP_NULL ) {
                    constop = cUNOPx(first)->op_first;
                }
                
                if ( !constop || constop->op_type != OP_CONST )
                    break;
                
                sv = cSVOPx_sv(constop);
                /* PL_curstash will msot likely be pointing to %main::,
                 * but we want the stash that this OP will be run under.
                 * This is important, because if they did
                 *    sort foo 1..10
                 * then all we'll get is a 'foo', which without this,
                 * we would end up looking in main::foo
                 */
                PL_curstash  = CopSTASH((COP*)nextstate);
                gv = gv_fetchsv(sv, 0, SVt_PVCV);
                PL_curstash  = curstash;
                
                if (!gv)
                    break;
                
                cv = GvCV(gv);
                
                if (!cv || !SvPOK(cv))
                    break;
                
                protolen = CvPROTOLEN(cv);
                proto = CvPROTO(cv);
                
                if (protolen == 2 && memEQ(proto, "$$", 2)) {
                    break;
                }
                else {
                    SV *const buffer = sv_newmortal();
                    gv = CvGV(cv) ? CvGV(cv) : gv;
                    gv_efullname3(buffer, gv, NULL);
                    warnif3(sort_prototype,
                        "Subroutine %"SVf"() used as first argument to sort, but has a %s prototype", buffer, proto);
                }
                break;
            }
        }
    }
    PL_curcop = &PL_compiling;
    prev_rpeepp(aTHX_ orig_o);
}

MODULE = warnings::pedantic PACKAGE = warnings::pedantic

PROTOTYPES: DISABLE

void
start(SV *classname, U32 ped, U32 vg, U32 vc, U32 vp, U32 sop)
CODE:
    pedantic   = ped;
    void_grep  = vg;
    void_close = vc;
    void_print = vp;
    sort_prototype = sop;
    if (!prev_rpeepp) {
        prev_rpeepp = WP_PEEP;
        WP_PEEP  = my_rpeep;
    }

void
done(SV *classname)
CODE:
    if ( WP_PEEP == my_rpeep ) {
        WP_PEEP = prev_rpeepp;
    }
    else {
        croak("WOAH THERE!! Something has gone HORRIBLY wrong!");
    }
