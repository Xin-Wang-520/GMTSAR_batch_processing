/*	$Id$	*/
/****************************************************************************
 *  Program to project a longitude, latitude, and topography
 *  into a file of range, azimuth, and topography.
 *  The basic approach is to :
 *   1 Read the header of the master radar image.  This supplies
 *     the radar co-ordinate system as well as the start and stop
 *     times for the orbit calculation.
 *   2 Read the topography data and convert to xyz positions.
 *   3 Fly the satellite along its orbit and determine the time
 *     of closest approach to each of the xyz points.   The program
 *     must have local access to the LED-file for the master.
 *   4 For each of the xyz points, calculate range, azimuth and topography
 ****************************************************************************/
/***************************************************************************
 * Creator:  Xiaopeng Tong and David T. Sandwell                           *
 *           (Scripps Institution of Oceanography)                         *
 * Date   :  08/10/2006                                                    *
 ***************************************************************************/
/***************************************************************************
 * Xiaohua Xu & David Sandwell: changed the search part to do polynomial   *
 * refinement. Forgot when this was done, sometime around 2015             *
 ***************************************************************************/
/***************************************************************************
 * Modification history:                                                   *
 *                                                                         *
 * DATE                                                                    *
 * 03/07/25 - making the module parallel                                   *
 * 12/15/07 - modified to work with complete grids                         *
 * 01/29/08 - modified to increase speed using the Golden Section Search   *
 * 04/13/08 - modified to give muiltiple choice of output                  *
 *            (single,double of binary or acsii)                           *
 * The algorithm is called Golden Section Search in One                    *
 * dimensional. Refer to Numerical Recipes for further details.            *
 * There is a deadly error in the NR edit 2nd:                             *
 * SHFT3(x0,x1,x2,R*x1+C*x3)                                               *
 * should be: SHFT3(x0,x1,x2,R*x3+C*x1)                                    *
 * Same error occurs at the nearby line.(2 lines below)                    *
 * The inputs for the program are 3 coordinates of a point in space        *
 * The function of the distance is in the same file.                       *
 * The function of the orbit is achieved by getorb_alos_                   *
 * the outputs are minimum range from the orbit to the point and the time. *
 * 09/17/08 - modified to read the orbit position all in once into an      *
 * array to speed up. That is to say, modify both the goldop subrountine   *
 * to use the orb_position array and the getorb_alos in the  main program  *
 * to read the array.                                                      *
 * 06/04/09 - update the range sampling rate from new PRM file to solve    *
 * confict of rng_samp_rate between LED file and PRM file in FBD mode.     *
 * 04/28/10 - modified to work with envisat - M.Wei			   *
 ****************************************************************************/

#include "gmtsar.h"
#include "llt2xyz.h"
#include "orbit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
//#include </opt/homebrew/opt/libomp/include/omp.h> 
#include <omp.h>
#define R 0.61803399
#define SHFT2(a, b, c)                                                                                                           \
	(a) = (b);                                                                                                                   \
	(b) = (c);
#define SHFT3(a, b, c, d)                                                                                                        \
	(a) = (b);                                                                                                                   \
	(b) = (c);                                                                                                                   \
	(c) = (d);
#define TOL 2

char *USAGE = " \n Usage: "
	              "SAT_llt2rat_para master.PRM dem.grd [-bo[s|d]] > outputfile  \n\n"
	              "             master.PRM   -  parameter file for master image and points "
	              "to LED orbit file \n"
	              "             dem.grd      -  digital elevation model in GMT grid format \n"
	              "             outputfile   -  range, azimuth, elevation(ref to radius in PRM), lon, lat [ASCII "
	              "default] \n"
	              "             -bos or -bod -  binary single or double precision output \n"
	              " \n"
	              " Notes: finite DEM nodes inside PRM data coverage are written to stdout. \n"
	              "        NaN DEM nodes and out-of-coverage points are skipped. \n"
	              " \n"
	              " example: SAT_llt2rat_para master.PRM dem.grd -bod > trans.dat    \n";

int npad = 8000;
const double C = 0.382;
void read_orb(FILE *, struct SAT_ORB *);
void set_prm_defaults(struct PRM *);
void hermite_c(double *, double *, double *, int, int, double, double *, int *);
void set_prm_defaults(struct PRM *);
void interpolate_SAT_orbit_slow(struct SAT_ORB *orb, double time, double *, double *, double *, int *);
void polyfit(double *, double *, double *, int *, int *);

int main(int argc, char **argv) {
        /* set number of threads*/
        //omp_set_num_threads(8);

	FILE *fprm1 = NULL;
	int otype;
	double rln, rlt, rht, dr, t1, t11, t2, tm;
	double ts, rng0;
	double xp[3];
	double xt[3];
	double rp[3];
	double dd[5]; /* dummy for output  double precision */
	float ds[5];  /* dummy for output  single precision */
	double r0, rf, a0, af;
	double fll, rdd, daa, drr, dopc;
	double dt, dtt, xs, ys, zs;
	double times[20], rng[20], d[3]; /* arrays used for polynomial refinement of min range */
        double vec1[3], vec2[3], vec0[3], det = 1.0;
	int ir, k, ntt = 10, nc = 3;    /* size of arrays used for polynomial refinement */
	int i,j, row, col, nrec, precise = 1;
	int goldop();
	int stai, endi, midi, lookdir;
	double **orb_pos = NULL;
	struct PRM prm;
	struct SAT_ORB *orb = NULL;
	char name[128], value[128];
	double rsr;
	FILE *ldrfile = NULL;
	struct GMTAPI_CTRL *GMT =NULL;
        struct GMT_GRID *DEM = NULL;
	        double *dem=NULL;
	        double **out = NULL;
	        int *valid = NULL;
	        double *xvec=NULL, *yvec=NULL ;
        void *API = NULL;
        time_t start_total, end_total;  // start and end of total time
        time_t start, end;             // start and end of section time
        double time1, time2, time3, total_time;
	int calorb_alos(struct SAT_ORB *, double **orb_pos, double ts, double t1, int nrec);

        start_total = time(NULL); 
	/* Make sure usage is correct and files can be opened  */

	if (argc < 3 || argc > 4) {
		fprintf(stderr, "%s\n", USAGE);
		exit(-1);
	}
	//precise = atoi(argv[2]);

	/* otype:    1 -- ascii; 2 -- single precision binary; 3 -- double precision
	 * binary    */

	otype = 1;
	if (argc == 4) {
		if (!strcmp(argv[3], "-bos"))
			otype = 2;
		else if (!strcmp(argv[3], "-bod"))
			otype = 3;
		else {
				fprintf(stderr, " %s *** option not recognized ***\n\n", argv[3]);
			fprintf(stderr, "%s", USAGE);
			exit(1);
		}
	}
        
	/*  open and read the parameter file */
        start = time(NULL);
	if ((fprm1 = fopen(argv[1], "r")) == NULL) {
		fprintf(stderr, "couldn't open master.PRM \n");
		fprintf(stderr, "%s\n", USAGE);
		exit(-1);
	}
 
	/* initialize the prm file   */

	null_sio_struct(&prm);
	set_prm_defaults(&prm);
	get_sio_struct(fprm1, &prm);

	fclose(fprm1);

        lookdir = 1;
        if (strcmp(prm.lookdir,"L") == 0) {
      	  //fprintf(stderr,"SAT is left looking\n");
        	lookdir = -1;
        }

	/*  get the orbit data */

	ldrfile = fopen(prm.led_file, "r");
	if (ldrfile == NULL)
		die("can't open ", prm.led_file);
	orb = (struct SAT_ORB *)malloc(sizeof(struct SAT_ORB));
	read_orb(ldrfile, orb);

	dr = 0.5 * SOL / prm.fs;
	r0 = -10.;
	rf = prm.num_rng_bins + 10.;
	a0 = -20.;
	af = prm.num_patches * prm.num_valid_az + 20.;

	/* compute the flattening */

	fll = (prm.ra - prm.rc) / prm.ra;

	/* compute the start time, stop time and increment */

	t1 = 86400. * prm.clock_start + (prm.nrows - prm.num_valid_az) / (2. * prm.prf);
	t2 = t1 + prm.num_patches * prm.num_valid_az / prm.prf;

	/* sample the orbit only every 2th point or about 8 m along track */
	/* if this is S1A which has a low PRF sample 2 times more often */

	ts = 2. / prm.prf;
	if (prm.prf < 600.) {
		ts = 2. / (2. * prm.prf);
		npad = 20000;
	}
	nrec = (int)((t2 - t1) / ts);

	/* allocate storage for an array of pointers  */

	orb_pos = malloc(4 * sizeof(double *));

	/* for each pointer, allocate storage for an array of floats  */

	for (j = 0; j < 4; j++) {
		orb_pos[j] = malloc((nrec + 2 * npad) * sizeof(double));
	}
        
	/* read in the postion of the orbit */
      
	(void)calorb_alos(orb, orb_pos, ts, t1, nrec);

	/* Begin: Initializing new GMT session*/
        if ((API = GMT_Create_Session(argv[0], 0U, GMT_SESSION_EXTERNAL, NULL)) == NULL)
		return EXIT_FAILURE;

        /* read in the dem file */
        if ((DEM = GMT_Read_Data(API, GMT_IS_GRID, GMT_IS_FILE, GMT_IS_SURFACE, GMT_GRID_ALL, NULL, argv[2] , NULL )) == NULL )
        	die ("could not open dem file ", argv[2]);
        int n_columns=DEM->header->n_columns;
        int n_rows=DEM->header->n_rows;
        xvec = (double *)malloc(n_columns*sizeof(double));
        yvec = (double *)malloc(n_rows*sizeof(double));
        dem = (double *) malloc(n_columns*n_rows*sizeof(double));
		out = (double **)malloc(n_columns * n_rows * sizeof(double *));
	        valid = (int *)calloc(n_columns * n_rows, sizeof(int));
	        for (int i = 0; i < n_columns * n_rows; i++) {
	       	        out[i] = (double *)malloc(5 * sizeof(double));  
	        }

        /* Match the six-decimal text precision and ties-to-even rounding used by
         * the original pipeline:
         * gmt grd2xyz --FORMAT_FLOAT_OUT=%lf dem.grd -s | SAT_llt2rat ...
         * This keeps blockmedian bin assignment compatible with dem2topo_ra.csh.
         */
        for (j = 0; j<n_columns; j++)
                xvec[j] = nearbyint((DEM->header->wesn[0] + DEM->header->inc[0]*j) * 1.0e6) / 1.0e6;
        for (j = 0; j<n_rows; j++)
                yvec[j] = nearbyint((DEM->header->wesn[3] - DEM->header->inc[1]*j) * 1.0e6) / 1.0e6;
        for (int i=0; i< n_columns * n_rows; i++) {
		dem[i] = nearbyint((double)DEM->data[i] * 1.0e6) / 1.0e6;
        }
        end = time(NULL);
        time1 = difftime(end, start);  
        fprintf(stderr,"read time: %.6f seconds\n", time1);
        
        /* OpenMp Parallel */
        start = time(NULL);
	        #pragma omp parallel for schedule(guided) collapse(2) \
	        private(row, col, rp, xp, xt, xs, ys, zs, rng, times, d, vec0, vec1, vec2, det, rng0, tm, dt, t11, dtt, dopc, rdd, daa, drr, stai, endi, midi, k, ir) \
	        firstprivate(precise, C) \
	        shared(orb, lookdir, dr, r0, rf, a0, af, otype, fll, out, valid, xvec, yvec, dem, prm)
        for ( row = 0; row < n_rows ; row++) {
                for ( col = 0; col < n_columns; col++) {    
                /* read the llt points and convert to xyz.  */
                        rp[0] = yvec[row];
                        rp[1] = xvec[col];
                        rp[2] = dem[row * n_columns + col];
	                        if (isnan(rp[2]))
	                                continue;   
                        plh2xyz(rp, xp, prm.ra, fll);
                        if (rp[1] > 180.)
                                rp[1] = rp[1] - 360.;
                        xt[0] = -1.0;

        /* compute the topography due to the difference between the local radius and
 * center radius */

                        rp[2] = sqrt(xp[0] * xp[0] + xp[1] * xp[1] + xp[2] * xp[2]) - prm.RE;

        /* minimum for each point */

                        stai = 0;
                        endi = nrec + npad * 2 - 1;
                        midi = (stai + (endi - stai) * C);
                        (void)goldop(ts, t1, orb_pos, stai, endi, midi, xp[0], xp[1], xp[2], &rng0, &tm);

                        if (precise == 1) {

        /* refine this minimum range and azimuth with a polynomial fit */
                                dt = 1. / ntt; /* make the polynomial 1 second long */
                                for (k = 0; k < ntt; k++) {
                                        times[k] = dt * (k - ntt / 2 + .5);
                                        t11 = tm + times[k];
                                        interpolate_SAT_orbit_slow(orb, t11, &xs, &ys, &zs, &ir);
                                        rng[k] = sqrt((xp[0] - xs) * (xp[0] - xs) + (xp[1] - ys) * (xp[1] - ys) + (xp[2] - zs) * (xp[2] - zs)) - rng0;
                                        if(k == 0) {
                                                vec0[0] = xs; vec0[1] = ys; vec0[2] = zs;
                                        }
                                        if(k == ntt-1) {
                                                vec1[0] = xs; vec1[1] = ys; vec1[2] = zs;
                                        }
                                }
                                vec1[0] = vec1[0] - vec0[0]; vec1[1] = vec1[1] - vec0[1]; vec1[2] = vec1[2] - vec0[2];
            
        /* fit a second order polynomial to the range versus time function and
 * update the tm and rng0 */
                               polyfit(times, rng, d, &ntt, &nc);
                               dtt = -d[1] / (2. * d[2]);
                               tm = tm + dtt;
                               interpolate_SAT_orbit_slow(orb, tm, &xs, &ys, &zs, &ir);
                               rng0 = sqrt((xp[0] - xs) * (xp[0] - xs) + (xp[1] - ys) * (xp[1] - ys) + (xp[2] - zs) * (xp[2] - zs));
                               vec2[0] = xp[0] - xs; vec2[1] = xp[1] - ys; vec2[2] = xp[2] - zs;
        
        /* first compute curl of vec-s and determine whether the range is really positive
           * with (a2b3-a3b2)i, (a3b1-a1b3)j, (a1b2 - a2b1)k projected to xs, ys, zs*/
                               det = (vec2[1]*vec1[2]-vec2[2]*vec1[1])*xs + (vec2[2]*vec1[0]-vec2[0]*vec1[2])*ys + (vec2[0]*vec1[1]-vec2[1]*vec1[0])*zs;
                               if (det * (double)lookdir > 0) {
                                       det = 1.0;
                               } 
                               else {
                                       det = -1.0;
                               }
                        }

        /* compute the range and azimuth in pixel space */
                        xt[0] = rng0 * det;
                        xt[1] = tm;
                        xt[0] = (xt[0] - prm.near_range) / dr - (prm.rshift + prm.sub_int_r) + prm.chirp_ext;
                        xt[1] = prm.prf * (xt[1] - t1) - (prm.ashift + prm.sub_int_a);

        /* For Envisat correct for biases based on Pinon reflector analysis */
                        if (prm.SC_identity == 4) {
                                xt[0] = xt[0] + 8.4;
                                xt[1] = xt[1] + 4;
                        }

        /* compute the azimuth and range correction if the Doppler is not zero */
   
                        if (prm.fd1 != 0.) {
                                dopc = prm.fd1 + prm.fdd1 * (prm.near_range + dr * prm.num_rng_bins / 2.);
                                rdd = (prm.vel * prm.vel) / rng0;
                                daa = -0.5 * (prm.lambda * dopc) / rdd;
                                drr = 0.5 * rdd * daa * daa / dr;
                                daa = prm.prf * daa;
                                xt[0] = xt[0] + drr;
                                xt[1] = xt[1] + daa;
                        }
              
	                        if (xt[0] < r0 || xt[0] > rf || xt[1] < a0 || xt[1] > af)
	                                continue;
                        
                        out[row * n_columns + col][0] = xt[0];
                        out[row * n_columns + col][1] = xt[1];
	                        out[row * n_columns + col][2] = rp[2];
	                        out[row * n_columns + col][3] = rp[1];
	                        out[row * n_columns + col][4] = rp[0];
	                        valid[row * n_columns + col] = 1;

                }
        }
        end = time(NULL);
        time2 = difftime(end, start);
        fprintf(stderr,"compute time: %.6f seconds\n", time2);
        for (j = 0; j < 4; j++) {
		free(orb_pos[j]);
	}
	free(orb_pos);
	free(orb);
	free(xvec);
        free(yvec);
        free(dem);
        GMT_Destroy_Data(API,&DEM);
     
        /*data output*/
        start = time(NULL);
	        //#pragma omp parallel for schedule(static) private(i, ds, dd) shared(n_columns, n_rows, out, otype)
	        for (i = 0; i < n_columns * n_rows; i++) {
	                if (!valid[i])
	                        continue;
	                if (otype == 1) {
                        fprintf(stdout, "%.9f %.9f %.9f %.9f %.9f \n", out[i][0], out[i][1], out[i][2], out[i][3], out[i][4]);
                }
                else if (otype == 2) {
                        ds[0] = (float)out[i][0];
                        ds[1] = (float)out[i][1];
                        ds[2] = (float)out[i][2];
                        ds[3] = (float)out[i][3];
                        ds[4] = (float)out[i][4];
                        fwrite(ds, sizeof(float), 5, stdout);
                }
                else if (otype == 3) {
                        dd[0] = out[i][0];
                        dd[1] = out[i][1];
                        dd[2] = out[i][2];
                        dd[3] = out[i][3];
                        dd[4] = out[i][4];
                fwrite(dd, sizeof(double), 5, stdout);
                }
        }
        end = time(NULL);
        time3 = difftime(end, start);
        fprintf(stderr,"write time: %.6f seconds\n", time3);
        
        /*compute and print total time*/
        end_total = time(NULL);
        total_time = difftime(end_total, start_total);
        fprintf(stderr,"Total time: %.6f seconds\n", total_time);
        
	/* free the array  */
	        for (int i = 0; i < n_columns * n_rows; i++) {
	               free(out[i]);
	        }
	        free(out);
	        free(valid);
	
	return (0);
}

/*    subfunctions    */

int goldop(double ts, double t1, double **orb_pos, int ax, int bx, int cx, double xpx, double xpy, double xpz, double *rng,
           double *tm) {

	/* use golden section search to find the minimum range between the target and
	 * the orbit */
	/* xpx, xpy, xpz is the position of the target in cartesian coordinate */
	/* ax is stai; bx is endi; cx is midi it's easy to tangle */

	double f1, f2;
	int x0, x1, x2, x3;
	int xmin;
	double dist();

	x0 = ax;
	x3 = bx;
	//      if (fabs(bx-cx) > fabs(cx-ax)) {
	if (abs(bx - cx) > abs(cx - ax)) {
		x1 = cx;
		x2 = cx + (int)fabs((C * (bx - cx)));
	}
	else {
		x2 = cx;
		x1 = cx - (int)fabs((C * (cx - ax))); /* make x0 to x1 the smaller segment */
	}

	f1 = dist(xpx, xpy, xpz, x1, orb_pos);
	f2 = dist(xpx, xpy, xpz, x2, orb_pos);

	while ((x3 - x0) > TOL && (x2 != x1)) {
		if (f2 < f1) {
			SHFT3(x0, x1, x2, (int)(R * x3 + C * x1));
			SHFT2(f1, f2, dist(xpx, xpy, xpz, x2, orb_pos));
		}
		else {
			SHFT3(x3, x2, x1, (int)(R * x0 + C * x2));
			SHFT2(f2, f1, dist(xpx, xpy, xpz, x1, orb_pos));
		}
	}

	if (f1 < f2) {
        if (x1 <= bx && x1 >= ax) {
		    xmin = x1;
        }
        else{
            xmin = abs(x1-bx) > abs(x1-ax) ? ax : bx;
        }
		*tm = orb_pos[0][x1];
		*rng = f1;
	}
	else {
        if (x2 <= bx && x2 >= ax) {
		    xmin = x2;
        }
        else {
            xmin = abs(x2-bx) > abs(x2-ax) ? ax : bx;
        }
		*tm = orb_pos[0][x2];
		*rng = f2;
	}

	return (xmin);
}

double dist(double x, double y, double z, int n, double **orb_pos) {

	double d, dx, dy, dz;

	dx = x - orb_pos[1][n];
	dy = y - orb_pos[2][n];
	dz = z - orb_pos[3][n];
	d = sqrt(dx * dx + dy * dy + dz * dz);

	return (d);
}

int calorb_alos(struct SAT_ORB *orb, double **orb_pos, double ts, double t1, int nrec)
/* function to calculate every position in the orbit   */

{
	int i, k, nval;
	// int     npad = 8000;   /* number of buffer points to add before and after
	// the acquisition */
	int ir;            /* return code: 0 = ok; 1 = interp not in center; 2 = time out of
	                      range */
	double xs, ys, zs; /* position at time */
	double *pt, *px, *py, *pz, *pvx, *pvy, *pvz;
	double pt0;
	double times;

	px = (double *)malloc(orb->nd * sizeof(double));
	py = (double *)malloc(orb->nd * sizeof(double));
	pz = (double *)malloc(orb->nd * sizeof(double));
	pvx = (double *)malloc(orb->nd * sizeof(double));
	pvy = (double *)malloc(orb->nd * sizeof(double));
	pvz = (double *)malloc(orb->nd * sizeof(double));
	pt = (double *)malloc(orb->nd * sizeof(double));

	pt0 = 86400. * orb->id + orb->sec;
	for (k = 0; k < orb->nd; k++) {
		pt[k] = pt0 + k * orb->dsec;
		px[k] = orb->points[k].px;
		py[k] = orb->points[k].py;
		pz[k] = orb->points[k].pz;
		pvx[k] = orb->points[k].vx;
		pvy[k] = orb->points[k].vy;
		pvz[k] = orb->points[k].vz;
	}

	nval = 6;

	/* loop to get orbit position of every point and store them into orb_pos */
	for (i = 0; i < nrec + npad * 2; i++) {
		times = t1 - npad * ts + i * ts;
		orb_pos[0][i] = times;

		hermite_c(pt, px, pvx, orb->nd, nval, times, &xs, &ir);
		hermite_c(pt, py, pvy, orb->nd, nval, times, &ys, &ir);
		hermite_c(pt, pz, pvz, orb->nd, nval, times, &zs, &ir);

		orb_pos[1][i] = xs;
		orb_pos[2][i] = ys;
		orb_pos[3][i] = zs;
	}

	free((double *)px);
	free((double *)py);
	free((double *)pz);
	free((double *)pt);
	free((double *)pvx);
	free((double *)pvy);
	free((double *)pvz);

	return orb->nd;
}
