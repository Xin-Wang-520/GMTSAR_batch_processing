# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True
# distutils: extra_compile_args = -O3
# Modified by Xin Wang, USTC, Hefei, China
# Last updated: July 21, 2026

"""Bit-identical Cython kernel for the independent GMT-surface implementation."""

import numpy as np
cimport numpy as cnp
from libc.math cimport fabs, sqrt

ctypedef cnp.float32_t f32
ctypedef cnp.uint8_t u8

cdef extern from *:
    """
    #include <math.h>
    static void clone_exact_bcs(float *u, int ny, int nx, double bt, double alpha) {
        int col, row, mx = nx + 4;
        long nw = 2 * mx + 2, ne = nw + nx - 1;
        long sw = nw + (ny - 1) * mx, se = sw + nx - 1, n;
        int N2=-2*mx, NW=-mx-1, N1=-mx, NE=-mx+1, W2=-2, W1=-1;
        int E1=1, E2=2, SW=mx-1, S1=mx, SE=mx+1, S2=2*mx;
        double x0=4.0*(1.0-bt)/(2.0-bt), x1=(3.0*bt-2.0)/(2.0-bt);
        double yd=2.0*alpha*(1.0-bt)+bt;
        double y0=4.0*alpha*(1.0-bt)/yd, y1=(bt-2.0*alpha*(1.0-bt))/yd;
        double ep2=alpha*alpha, em2=1.0/ep2, tp=2.0+2.0*ep2, tm=2.0+2.0*em2;
        long ns=sw, nn=nw;
        for(col=0;col<nx;col++,ns++,nn++) { u[ns+S1]=(float)(y0*u[ns]+y1*u[ns+N1]); u[nn+N1]=(float)(y0*u[nn]+y1*u[nn+S1]); }
        long nwest=nw, neast=ne;
        for(row=0;row<ny;row++,nwest+=mx,neast+=mx) { u[nwest+W1]=(float)(x1*u[nwest+E1]+x0*u[nwest]); u[neast+E1]=(float)(x1*u[neast+W1]+x0*u[neast]); }
        n=sw; u[n+SW]=u[n+SE]+u[n+NW]-u[n+NE];
        n=nw; u[n+NW]=u[n+NE]+u[n+SW]-u[n+SE];
        n=se; u[n+SE]=u[n+SW]+u[n+NE]-u[n+NW];
        n=ne; u[n+NE]=u[n+NW]+u[n+SE]-u[n+SW];
        ns=sw; nn=nw;
        for(col=0;col<nx;col++,ns++,nn++) {
            u[ns+S2]=(float)(u[ns+N2]+em2*(u[ns+NW]+u[ns+NE]-u[ns+SW]-u[ns+SE])+tm*(u[ns+S1]-u[ns+N1]));
            u[nn+N2]=(float)(u[nn+S2]+em2*(u[nn+SW]+u[nn+SE]-u[nn+NW]-u[nn+NE])+tm*(u[nn+N1]-u[nn+S1]));
        }
        nwest=nw; neast=ne;
        for(row=0;row<ny;row++,nwest+=mx,neast+=mx) {
            u[nwest+W2]=(float)(u[nwest+E2]+ep2*(u[nwest+NE]+u[nwest+SE]-u[nwest+NW]-u[nwest+SW])+tp*(u[nwest+W1]-u[nwest+E1]));
            u[neast+E2]=(float)(u[neast+W2]+ep2*(u[neast+NW]+u[neast+SW]-u[neast+NE]-u[neast+SE])+tp*(u[neast+E1]-u[neast+W1]));
        }
    }
    static int clone_exact_iterate(float *u, unsigned char *status, float *briggs, int ny, int nx, int stride,
        double zrms, double conv, int maxit, double it, double bt, double alpha, double relax, double *last_change) {
        int mx=nx+4, off[12], p[5][4]={{0,0,0,0},{1,5,9,10},{8,9,6,3},{10,6,2,1},{3,2,5,8}};
        int row,col,k,q,set,iter=0,limit=maxit*stride; long node;
        double coeff[2][12], loose=1.0-it, a2=alpha*alpha, a4=a2*a2, one=1.0+a2;
        double a0=1.0/((6*a4*loose+10*a2*loose+8*loose-2*one)+4*it*one);
        double a01=2.0*loose*(1.0+a4), a02=2.0-it+2.0*loose*a2;
        double oldw=1.0-relax, u00, sum, change, maxchange, maxz;
        off[0]=-2*mx;off[1]=-mx-1;off[2]=-mx;off[3]=-mx+1;off[4]=-2;off[5]=-1;
        off[6]=1;off[7]=2;off[8]=mx-1;off[9]=mx;off[10]=mx+1;off[11]=2*mx;
        coeff[1][4]=coeff[1][7]=-loose; coeff[1][0]=coeff[1][11]=-loose*a4;
        coeff[0][4]=coeff[0][7]=-loose*a0; coeff[0][0]=coeff[0][11]=-loose*a4*a0;
        coeff[1][5]=coeff[1][6]=2*loose*one; coeff[0][5]=coeff[0][6]=(2*coeff[1][5]+it)*a0;
        coeff[1][2]=coeff[1][9]=coeff[1][5]*a2; coeff[0][2]=coeff[0][9]=coeff[0][5]*a2;
        coeff[1][1]=coeff[1][3]=coeff[1][8]=coeff[1][10]=-2*loose*a2;
        coeff[0][1]=coeff[0][3]=coeff[0][8]=coeff[0][10]=coeff[1][1]*a0;
        do {
            clone_exact_bcs(u,ny,nx,bt,alpha); maxchange=-1.0;
            for(row=0;row<ny;row++) { node=2*mx+2+(long)row*mx;
                for(col=0;col<nx;col++,node++) { q=status[node]; if(q==5) continue; u00=0.0; set=(q==0)?0:1;
                    for(k=0;k<12;k++) u00 += u[node+off[k]]*coeff[set][k];
                    if(set) { float *b=&briggs[((long)row*nx+col)*6]; sum=0.0;
                        for(k=0;k<4;k++) sum += b[k]*u[node+off[p[q][k]]];
                        u00=(u00+a02*(sum+b[4]))*b[5];
                    }
                    u00=u[node]*oldw+u00*relax; change=fabs(u00-u[node]); u[node]=(float)u00; if(change>maxchange)maxchange=change;
                }
            }
            iter++; maxz=maxchange*zrms;
        } while(maxz>conv/stride && iter<limit);
        *last_change=maxz; return iter;
    }
    """
    int clone_exact_iterate(float *, unsigned char *, float *, int, int, int, double, double, int, double, double, double, double, double *)


def detrend_normalize(
    cnp.ndarray[f32, ndim=2] data_array,
    double xlo,
    double ylo,
    double dx,
    double dy,
):
    """Apply GMT's sequential plane fit and float32 normalization in place."""
    cdef f32[:, :] data = data_array
    cdef Py_ssize_t k, n = data_array.shape[0]
    cdef double xx, yy, zz
    cdef double sx=0.0, sy=0.0, sz=0.0, sxx=0.0, sxy=0.0
    cdef double sxz=0.0, syy=0.0, syz=0.0
    cdef double den, a, b, c, ssz=0.0, rms
    cdef float plane_value, square, inv_rms
    for k in range(n):
        xx = (data[k, 0] - xlo) / dx
        yy = (data[k, 1] - ylo) / dy
        zz = data[k, 2]
        sx += xx; sy += yy; sz += zz; sxx += xx * xx
        sxy += xx * yy; sxz += xx * zz; syy += yy * yy; syz += yy * zz
    den = n*sxx*syy + 2.0*sx*sy*sxy - n*sxy*sxy - sx*sx*syy - sy*sy*sxx
    if den == 0.0:
        a = b = c = 0.0
    else:
        a = (sz*sxx*syy + sx*sxy*syz + sy*sxy*sxz - sz*sxy*sxy - sx*sxz*syy - sy*syz*sxx) / den
        b = (n*sxz*syy + sz*sy*sxy + sy*sx*syz - n*sxy*syz - sz*sx*syy - sy*sy*sxz) / den
        c = (n*sxx*syz + sx*sy*sxz + sz*sx*sxy - n*sxy*sxz - sx*sx*syz - sz*sy*sxx) / den
    for k in range(n):
        xx = (data[k, 0] - xlo) / dx
        yy = (data[k, 1] - ylo) / dy
        plane_value = <float>(a + b * xx + c * yy)
        data[k, 2] = data[k, 2] - plane_value
    for k in range(n):
        square = data[k, 2] * data[k, 2]
        ssz += square
    rms = sqrt(ssz / n)
    inv_rms = <float>(1.0 / rms)
    for k in range(n):
        data[k, 2] = data[k, 2] * inv_rms
    return a, b, c, rms


def set_constraints(
    cnp.ndarray[f32, ndim=2] data_array,
    cnp.ndarray[cnp.int64_t, ndim=1] chosen_array,
    cnp.ndarray[cnp.int64_t, ndim=1] rows_array,
    cnp.ndarray[cnp.int64_t, ndim=1] cols_array,
    cnp.ndarray[u8, ndim=2] status_array,
    cnp.ndarray[f32, ndim=3] briggs_array,
    cnp.ndarray[f32, ndim=2] grid_array,
    double xlo,
    double yhi,
    double inc_x,
    double inc_y,
    int stride,
    double slope_x,
    double slope_y,
    double rms,
    double tension,
):
    """Create constraints using the same C float evaluation as GMT 6.5."""
    cdef f32[:, :] data = data_array
    cdef cnp.int64_t[:] chosen = chosen_array
    cdef cnp.int64_t[:] rows = rows_array
    cdef cnp.int64_t[:] cols = cols_array
    cdef u8[:, :] status = status_array
    cdef f32[:, :, :] briggs = briggs_array
    cdef f32[:, :] grid = grid_array
    cdef Py_ssize_t k, n = chosen_array.shape[0]
    cdef int idx, row, col, quadrant
    cdef double x0, y0, dx, dy, xx, yy, xx2, yy2
    cdef double sum1, inv_sum1, inv_delta, b4
    cdef double loose = 1.0 - tension
    cdef double a0_const_1 = 4.0 * loose
    cdef double a0_const_2 = 2.0 - tension + 2.0 * loose
    cdef float b0, b1, b2, b3, b4z, b5, trend

    for k in range(n):
        idx = <int>chosen[k]
        row = <int>rows[k]
        col = <int>cols[k]
        x0 = xlo + col * inc_x
        y0 = yhi - row * inc_y
        dx = (data[idx, 0] - x0) / inc_x
        dy = (data[idx, 1] - y0) / inc_y
        if fabs(dx) < 0.05 and fabs(dy) < 0.05:
            status[row, col] = 5
            trend = <float>(stride * (slope_x * dx + slope_y * dy) / rms)
            grid[row + 2, col + 2] = data[idx, 2] + trend
            continue
        if dy >= 0.0:
            if dx >= 0.0:
                quadrant = 1; xx = dx; yy = dy
            else:
                quadrant = 2; yy = -dx; xx = dy
        else:
            if dx >= 0.0:
                quadrant = 4; yy = dx; xx = -dy
            else:
                quadrant = 3; xx = -dx; yy = -dy
        status[row, col] = quadrant
        sum1 = xx + yy
        inv_sum1 = 1.0 / (1.0 + sum1)
        inv_delta = inv_sum1 / sum1
        xx2 = xx * xx
        yy2 = yy * yy
        b0 = <float>((xx2 + 2.0 * xx * yy + xx - yy2 - yy) * inv_delta)
        b1 = <float>(2.0 * (yy - xx + 1.0) * inv_sum1)
        b2 = <float>(2.0 * (xx - yy + 1.0) * inv_sum1)
        b3 = <float>((-xx2 + 2.0 * xx * yy - xx + yy2 + yy) * inv_delta)
        b4 = 4.0 * inv_delta
        b5 = b0 + b1 + b2 + b3 + <float>b4
        b4z = <float>(b4 * data[idx, 2])
        b5 = <float>(1.0 / (a0_const_1 + a0_const_2 * b5))
        briggs[row, col, 0] = b0
        briggs[row, col, 1] = b1
        briggs[row, col, 2] = b2
        briggs[row, col, 3] = b3
        briggs[row, col, 4] = b4z
        briggs[row, col, 5] = b5


cdef inline void set_bcs(
    f32[:, :] u,
    int ny,
    int nx,
    double boundary_tension,
    double alpha,
) noexcept:
    cdef int r, c
    cdef int north = 2
    cdef int south = ny + 1
    cdef int west = 2
    cdef int east = nx + 1
    cdef double x0 = 4.0 * (1.0 - boundary_tension) / (2.0 - boundary_tension)
    cdef double x1 = (3.0 * boundary_tension - 2.0) / (2.0 - boundary_tension)
    cdef double yden = 2.0 * alpha * (1.0 - boundary_tension) + boundary_tension
    cdef double y0 = 4.0 * alpha * (1.0 - boundary_tension) / yden
    cdef double y1 = (boundary_tension - 2.0 * alpha * (1.0 - boundary_tension)) / yden
    cdef double eps_p2 = alpha * alpha
    cdef double eps_m2 = 1.0 / eps_p2
    cdef double two_plus_ep2 = 2.0 + 2.0 * eps_p2
    cdef double two_plus_em2 = 2.0 + 2.0 * eps_m2

    # First natural boundary equation on north/south sides.
    for c in range(west, east + 1):
        u[south + 1, c] = y0 * u[south, c] + y1 * u[south - 1, c]
        u[north - 1, c] = y0 * u[north, c] + y1 * u[north + 1, c]

    # First natural boundary equation on west/east sides.
    for r in range(north, south + 1):
        u[r, west - 1] = x1 * u[r, west + 1] + x0 * u[r, west]
        u[r, east + 1] = x1 * u[r, east - 1] + x0 * u[r, east]

    # Mixed second derivative is zero at the four corners.
    u[south + 1, west - 1] = (
        u[south + 1, west + 1] + u[south - 1, west - 1] - u[south - 1, west + 1]
    )
    u[north - 1, west - 1] = (
        u[north - 1, west + 1] + u[north + 1, west - 1] - u[north + 1, west + 1]
    )
    u[south + 1, east + 1] = (
        u[south + 1, east - 1] + u[south - 1, east + 1] - u[south - 1, east - 1]
    )
    u[north - 1, east + 1] = (
        u[north - 1, east - 1] + u[north + 1, east + 1] - u[north + 1, east - 1]
    )

    # Zero normal derivative of curvature: second ghost rows.
    for c in range(west, east + 1):
        u[south + 2, c] = (
            u[south - 2, c]
            + eps_m2 * (
                u[south - 1, c - 1] + u[south - 1, c + 1]
                - u[south + 1, c - 1] - u[south + 1, c + 1]
            )
            + two_plus_em2 * (u[south + 1, c] - u[south - 1, c])
        )
        u[north - 2, c] = (
            u[north + 2, c]
            + eps_m2 * (
                u[north + 1, c - 1] + u[north + 1, c + 1]
                - u[north - 1, c - 1] - u[north - 1, c + 1]
            )
            + two_plus_em2 * (u[north - 1, c] - u[north + 1, c])
        )

    # Zero normal derivative of curvature: second ghost columns.
    for r in range(north, south + 1):
        u[r, west - 2] = (
            u[r, west + 2]
            + eps_p2 * (
                u[r - 1, west + 1] + u[r + 1, west + 1]
                - u[r - 1, west - 1] - u[r + 1, west - 1]
            )
            + two_plus_ep2 * (u[r, west - 1] - u[r, west + 1])
        )
        u[r, east + 2] = (
            u[r, east - 2]
            + eps_p2 * (
                u[r - 1, east - 1] + u[r + 1, east - 1]
                - u[r - 1, east + 1] - u[r + 1, east + 1]
            )
            + two_plus_ep2 * (u[r, east + 1] - u[r, east - 1])
        )


def iterate(
    cnp.ndarray[f32, ndim=2] u_array,
    cnp.ndarray[u8, ndim=2] status_array,
    cnp.ndarray[f32, ndim=3] briggs_array,
    int stride,
    double z_rms,
    double converge_limit,
    int max_iterations,
    double interior_tension=0.1,
    double boundary_tension=0.1,
    double alpha=1.0,
    double relaxation=1.4,
):
    """Run GMT's in-place row-major SOR iteration for one multigrid level."""
    cdef f32[:, :] u = u_array
    cdef u8[:, :] status = status_array
    cdef f32[:, :, :] briggs = briggs_array
    cdef int ny = status_array.shape[0]
    cdef int nx = status_array.shape[1]
    cdef int r, c, q, iteration = 0
    cdef int limit_iterations = max_iterations * stride
    cdef double loose = 1.0 - interior_tension
    cdef double alpha2 = alpha * alpha
    cdef double alpha4 = alpha2 * alpha2
    cdef double one_plus_e2 = 1.0 + alpha2
    cdef double a0 = 1.0 / (
        (6.0 * alpha4 * loose + 10.0 * alpha2 * loose + 8.0 * loose - 2.0 * one_plus_e2)
        + 4.0 * interior_tension * one_plus_e2
    )
    cdef double a0_const_1 = 2.0 * loose * (1.0 + alpha4)
    cdef double a0_const_2 = 2.0 - interior_tension + 2.0 * loose * alpha2
    cdef double c_w2 = -loose
    cdef double c_n2 = -loose * alpha4
    cdef double c_w1 = 2.0 * loose * one_plus_e2
    cdef double c_n1 = c_w1 * alpha2
    cdef double c_diag = -2.0 * loose * alpha2
    cdef double u_w2 = c_w2 * a0
    cdef double u_n2 = c_n2 * a0
    cdef double u_w1 = (2.0 * c_w1 + interior_tension) * a0
    cdef double u_n1 = u_w1 * alpha2
    cdef double u_diag = c_diag * a0
    cdef double old_weight = 1.0 - relaxation
    cdef double target, old, delta, max_delta, max_z_change = 0.0
    cdef double bk

    while True:
        set_bcs(u, ny, nx, boundary_tension, alpha)
        max_delta = 0.0
        for r in range(ny):
            for c in range(nx):
                q = status[r, c]
                if q == 5:
                    continue
                if q == 0:
                    # Preserve surface.c's N2,NW,N1,...,S2 summation order.
                    target = 0.0
                    target += u[r, c + 2] * u_n2
                    target += u[r + 1, c + 1] * u_diag
                    target += u[r + 1, c + 2] * u_n1
                    target += u[r + 1, c + 3] * u_diag
                    target += u[r + 2, c] * u_w2
                    target += u[r + 2, c + 1] * u_w1
                    target += u[r + 2, c + 3] * u_w1
                    target += u[r + 2, c + 4] * u_w2
                    target += u[r + 3, c + 1] * u_diag
                    target += u[r + 3, c + 2] * u_n1
                    target += u[r + 3, c + 3] * u_diag
                    target += u[r + 4, c + 2] * u_n2
                else:
                    target = 0.0
                    target += u[r, c + 2] * c_n2
                    target += u[r + 1, c + 1] * c_diag
                    target += u[r + 1, c + 2] * c_n1
                    target += u[r + 1, c + 3] * c_diag
                    target += u[r + 2, c] * c_w2
                    target += u[r + 2, c + 1] * c_w1
                    target += u[r + 2, c + 3] * c_w1
                    target += u[r + 2, c + 4] * c_w2
                    target += u[r + 3, c + 1] * c_diag
                    target += u[r + 3, c + 2] * c_n1
                    target += u[r + 3, c + 3] * c_diag
                    target += u[r + 4, c + 2] * c_n2
                    if q == 1:
                        bk = (
                            briggs[r, c, 0] * u[r + 1, c + 1]
                            + briggs[r, c, 1] * u[r + 2, c + 1]
                            + briggs[r, c, 2] * u[r + 3, c + 2]
                            + briggs[r, c, 3] * u[r + 3, c + 3]
                        )
                    elif q == 2:
                        bk = (
                            briggs[r, c, 0] * u[r + 3, c + 1]
                            + briggs[r, c, 1] * u[r + 3, c + 2]
                            + briggs[r, c, 2] * u[r + 2, c + 3]
                            + briggs[r, c, 3] * u[r + 1, c + 3]
                        )
                    elif q == 3:
                        bk = (
                            briggs[r, c, 0] * u[r + 3, c + 3]
                            + briggs[r, c, 1] * u[r + 2, c + 3]
                            + briggs[r, c, 2] * u[r + 1, c + 2]
                            + briggs[r, c, 3] * u[r + 1, c + 1]
                        )
                    else:
                        bk = (
                            briggs[r, c, 0] * u[r + 1, c + 3]
                            + briggs[r, c, 1] * u[r + 1, c + 2]
                            + briggs[r, c, 2] * u[r + 2, c + 1]
                            + briggs[r, c, 3] * u[r + 3, c + 1]
                        )
                    target = (
                        target
                        + a0_const_2 * (bk + briggs[r, c, 4])
                    ) * briggs[r, c, 5]

                old = u[r + 2, c + 2]
                target = old * old_weight + target * relaxation
                delta = fabs(target - old)
                u[r + 2, c + 2] = target
                if delta > max_delta:
                    max_delta = delta
        iteration += 1
        max_z_change = max_delta * z_rms
        if max_z_change <= converge_limit / stride or iteration >= limit_iterations:
            break

    return iteration, max_z_change


def iterate_c_exact(
    cnp.ndarray[f32, ndim=2] u_array,
    cnp.ndarray[u8, ndim=2] padded_status_array,
    cnp.ndarray[f32, ndim=3] briggs_array,
    int stride,
    double z_rms,
    double converge_limit,
    int max_iterations,
    double interior_tension=0.1,
    double boundary_tension=0.1,
    double alpha=1.0,
    double relaxation=1.4,
):
    cdef double last_change = 0.0
    cdef int ny = u_array.shape[0] - 4
    cdef int nx = u_array.shape[1] - 4
    cdef int count = clone_exact_iterate(
        &u_array[0, 0], &padded_status_array[0, 0], &briggs_array[0, 0, 0],
        ny, nx, stride, z_rms, converge_limit, max_iterations,
        interior_tension, boundary_tension, alpha, relaxation, &last_change,
    )
    return count, last_change
