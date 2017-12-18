;;; rubber.scm: rubber-sound stretches or contracts a sound (in time)
;;;   (rubber-sound 1.5) makes it 50% longer
;;;   rubber-sound looks for stable portions and either inserts or deletes periods 
;;;     period length is determined via autocorrelation

(provide 'snd-rubber.scm)

(define zeros-checked 8)
(define extension 10.0)
(define show-details #f)

;;; remove anything below 16Hz
;;; extend (src by 1/extension)
;;; collect upward zero-crossings
;;;   collect weights for each across next zeros-checked crossings
;;;   sort by least weight
;;;   ramp (out or in) and check if done

(define rubber-sound 
  ;; prepare sound (get rid of low freqs, resample)
  (let ()
    (define* (add-named-mark samp name snd chn)
      (let ((m (add-mark samp snd chn)))
	(set! (mark-name m) name)
	m))
    
    (define* (derumble-sound snd chn)
      (let ((old-length (framples snd chn)))
	(let ((fftlen (floor (expt 2 (ceiling (log (min old-length (srate snd)) 2)))))
	      (flt-env (list 0.0 0.0 (/ (* 2 16.0) (srate snd)) 0.0 (/ (* 2 20.0) (srate snd)) 1.0 1.0 1.0)))
	  (filter-sound flt-env fftlen snd chn)
	  (set! (framples snd chn) old-length))))
    
    (define* (sample-sound snd chn)
      (if (not (= extension 1.0))
	  (src-sound (/ 1.0 extension) 1.0 snd chn)))
    
    (define* (unsample-sound snd chn)
      ;; undo earlier interpolation
      (if (not (= extension 1.0))
	  (src-sound extension 1.0 snd chn)))
    
    (define (crossings)
      ;; return number of upward zero crossings that don't look like silence
      (let ((sr0 (make-sampler 0)))
	(do ((samp0 (next-sample sr0))
	     (crosses 0)
	     (len (framples))
	     (sum 0.0)
	     (last-cross 0)
	     (silence (* extension .001))
	     (i 0 (+ i 1)))
	    ((= i len)
	     crosses)
	  (let ((samp1 (next-sample sr0)))
	    (if (and (<= samp0 0.0)
		     (> samp1 0.0)
		     (> (- i last-cross) 4)
		     (> sum silence))
		(begin
		  (set! crosses (+ crosses 1))
		  (set! last-cross i)
		  (set! sum 0.0)))
	    (set! sum (+ sum (abs samp0)))
	    (set! samp0 samp1)))))
    
    (define (env-add s0 s1 samps)
      (let ((data (make-float-vector samps))
	    (x 1.0)
	    (xinc (/ 1.0 samps))
	    (sr0 (make-sampler (floor s0)))
	    (sr1 (make-sampler (floor s1))))
	(do ((i 0 (+ i 1)))
	    ((= i samps))
	  (set! (data i) (+ (* x (next-sample sr0))
			    (* (- 1.0 x) (next-sample sr1))))
	  (set! x (+ x xinc)))
	data))

    (lambda* (stretch snd chn)
      (as-one-edit
       (lambda ()
	 (derumble-sound snd chn)
	 (sample-sound snd chn)
	 
	 (let ((crosses (crossings)))
	   (let ((cross-samples (make-float-vector crosses))
		 (cross-weights (make-float-vector crosses))
		 (cross-marks (make-float-vector crosses))
		 (cross-periods (make-float-vector crosses)))
	     (let ((sr0 (make-sampler 0 snd chn))) ;; get cross points (sample numbers)
	       (do ((samp0 (next-sample sr0))
		    (len (framples))
		    (sum 0.0)
		    (last-cross 0)
		    (cross 0)
		    (silence (* extension .001))
		    (i 0 (+ i 1)))
		   ((= i len))
		 (let ((samp1 (next-sample sr0)))
		   (if (and (<= samp0 0.0)
			    (> samp1 0.0)
			    (> (- i last-cross) 40)
			    (> sum silence))
		       (begin
			 (set! last-cross i)
			 (set! sum 0.0)
			 (set! (cross-samples cross) i)
			 (set! cross (+ cross 1))))
		   (set! sum (+ sum (abs samp0)))
		   (set! samp0 samp1))))
	     
	     ;; now run through crosses getting period match info
	     (do ((i 0 (+ i 1)))
		 ((= i (- crosses 1)))
	       (let ((start (floor (cross-samples i)))
		     (autolen 0))
		 (let ((fftlen (floor (expt 2 (ceiling (log (* extension (/ (srate snd) 40.0)) 2))))))
		   (let ((len4 (/ fftlen 4))
			 (data (samples (floor start) fftlen)))
		     (autocorrelate data)
		     (set! autolen 0)
		     (do ((happy #f)
			  (j 1 (+ 1 j)))
			 ((or happy (= j len4)))
		       (when (and (< (data j) (data (+ j 1)))
				  (> (data (+ j 1)) (data (+ j 2))))
			 (set! autolen (* j 2))
			 (set! happy #t)))))
		 (let* ((next-start (+ start autolen))
			(min-i (+ i 1))
			(min-samps (floor (abs (- (cross-samples min-i) next-start))))
			(mink (min crosses (+ i zeros-checked))))
		   (do ((k (+ i 2) (+ k 1)))
		       ((= k mink))
		     (let ((dist (floor (abs (- (cross-samples k) next-start)))))
		       (if (< dist min-samps)
			   (begin
			     (set! min-samps dist)
			     (set! min-i k)))))
		   (let ((current-mark min-i)
			 (current-min 0.0))
		     
		     (let ((ampsum (make-one-pole 1.0 -1.0))
			   (diffsum (make-one-pole 1.0 -1.0)))
		       (do ((sr0 (make-sampler (floor start)))
			    (sr1 (make-sampler (floor (cross-samples current-mark))))
			    (samp0 0.0)
			    (i 0 (+ i 1)))
			   ((= i autolen))
			 (set! samp0 (next-sample sr0))
			 (one-pole ampsum (abs samp0))
			 (one-pole diffsum (abs (- (next-sample sr1) samp0))))
		       (set! diffsum (one-pole diffsum 0.0))
		       (set! ampsum (one-pole ampsum 0.0))
		       (set! current-min (if (= diffsum 0.0) 0.0 (/ diffsum ampsum))))
		     
		     (set! min-samps (round (* 0.5 current-min)))
		     (do ((top (min (- crosses 1) current-mark (+ i zeros-checked)))
			  (k (+ i 1) (+ k 1))
			  (wgt 0.0 0.0))
			 ((= k top))
		       (let ((ampsum (make-one-pole 1.0 -1.0))
			     (diffsum (make-one-pole 1.0 -1.0)))
			 (do ((sr0 (make-sampler (floor start)))
			      (sr1 (make-sampler (floor (cross-samples k))))
			      (samp0 0.0)
			      (i 0 (+ i 1)))
			     ((= i autolen))
			   (set! samp0 (next-sample sr0))
			   (one-pole ampsum (abs samp0))
			   (one-pole diffsum (abs (- (next-sample sr1) samp0))))
			 (set! diffsum (one-pole diffsum 0.0))
			 (set! ampsum (one-pole ampsum 0.0))
			 (set! wgt (if (= diffsum 0.0) 0.0 (/ diffsum ampsum))))
		       
		       (if (< wgt min-samps)
			   (begin
			     (set! min-samps (floor wgt))
			     (set! min-i k))))
		     
		     (if (not (= current-mark min-i))
			 (set! (cross-weights i) 1000.0) ; these are confused, so effectively erase them
			 (begin
			   (set! (cross-weights i) current-min)
			   (set! (cross-marks i) current-mark)
			   (set! (cross-periods i) (- (cross-samples current-mark) (cross-samples i)))
			   ))))))
	     ;; now sort weights to scatter the changes as evenly as possible
	     (let ((len (framples snd chn)))
	       (let ((adding (> stretch 1.0))
		     (samps (floor (* (abs (- stretch 1.0)) len)))
		     (weights (length cross-weights)))
		 (let ((needed-samps (if adding samps (min len (* samps 2))))
		       (handled 0)
		       (mult 1)
		       (curs 0)
		       (edits (make-float-vector weights)))
		   (do ((best-mark -1 -1)
			(old-handled handled handled))
		       ((or (= curs weights) (>= handled needed-samps)))
		     ;; need to find (more than) enough splice points to delete samps
		     (let ((cur 0)
			   (curmin (cross-weights 0))
			   (len (length cross-weights)))
		       (do ((i 0 (+ i 1)))
			   ((= i len))
			 (if (< (cross-weights i) curmin)
			     (begin
			       (set! cur i)
			       (set! curmin (cross-weights i)))))
		       (set! best-mark cur))
		     (set! handled (+ handled (floor (cross-periods best-mark))))
		     (if (or (< handled needed-samps)
			     (< (- handled needed-samps) (- needed-samps old-handled)))
			 (begin
			   (set! (edits curs) best-mark)
			   (set! curs (+ 1 curs))))
		     (set! (cross-weights best-mark) 1000.0))
		   
		   (if (>= curs weights)
		       (set! mult (ceiling (/ needed-samps handled))))
		   
		   (do ((changed-len 0)
			(weights (length cross-weights))
			(i 0 (+ i 1)))
		       ((or (= i curs) 
			    (> changed-len samps))
			(if show-details
			    (snd-print (format #f "wanted: ~D, got ~D~%" (floor samps) (floor changed-len)))))
		     (let* ((best-mark (floor (edits i)))
			    (beg (floor (cross-samples best-mark)))
			    (next-beg (floor (cross-samples (floor (cross-marks best-mark)))))
			    (len (floor (cross-periods best-mark))))
		       (when (> len 0)
			 (if adding
			     (let ((new-samps
				    (env-add beg next-beg len)))
			       (if show-details
				   (add-named-mark beg (format #f "~D:~D" i (floor (/ len extension)))))
			       (insert-samples beg len new-samps)
			       (if (> mult 1)
				   (do ((k 1 (+ k 1)))
				       ((= k mult))
				     (insert-samples (+ beg (* k len)) len new-samps)))
			       (set! changed-len (+ changed-len (* mult len)))
			       (do ((j 0 (+ 1 j)))
				   ((= j weights))
				 (let ((curbeg (floor (cross-samples j))))
				   (if (> curbeg beg)
				       (set! (cross-samples j) (+ curbeg len))))))
			     (begin
			       (if (>= beg (framples))
				   (snd-print (format #f "trouble at ~D: ~D of ~D~%" i beg (framples))))
			       (if show-details
				   (add-named-mark (- beg 1) (format #f "~D:~D" i (floor (/ len extension)))))
			       (delete-samples beg len)
			       (set! changed-len (+ changed-len len))
			       (do ((end (+ beg len))
				    (j 0 (+ 1 j)))
				   ((= j weights))
				 (let ((curbeg (floor (cross-samples j))))
				   (if (> curbeg beg)
				       (if (< curbeg end)
					   (set! (cross-periods j) 0)
					   (set! (cross-samples j) (- curbeg len)))))))))))
		   )))))
	 ;; and return to original srate
	 (unsample-sound snd chn)
	 (if show-details
	     (snd-print (format #f "~A -> ~A (~A)~%" (framples snd chn 0) (framples snd chn) (floor (* stretch (framples snd chn 0))))))
	 ) ; end of as-one-edit thunk
       (format #f "rubber-sound ~A" stretch)))))
  