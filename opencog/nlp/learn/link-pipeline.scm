;
; link-pipeline.scm
;
; Link-grammar word and link-counting pipeline.  Currently counts
; words, several kinds of word-pairs (links, and order-relations),
; and also disjuncts, parses and sentences.
;
; Copyright (c) 2013, 2017 Linas Vepstas <linasvepstas@gmail.com>
;
; This code is part of the language-learning effort.  The project
; requires that a lot of text be observed, withe the goal of deducing
; a grammar from it, using entropy and other basic probability methods.
;
; Main entry point: `(observe-text plain-text)`
;
; Call this entry point with exactly one sentance as a plain text
; string. It will be parsed by RelEx, and the resulting link-grammar
; link usage counts will be updated in the atomspace. The counts are
; flushed to the SQL database so that they're not forgotten.
;
; RelEx is used for only one reason: it prints out the required
; atomese format. The rule-engine in RelEx is NOT used!  This could
; be redesigned and XXX FIXME, it should be.
;
; This tracks multiple, independent counts:
; *) how many sentences have been observed.
; *) how many parses were observed.
; *) how many words have been observed (counting once-per-word)
; *) how many word-order pairs have been observed.
; *) the distance between words in the above pairs.
; *) how many link-relationship triples have been observed.
; *) how many disjuncts have been observed.
;
; Sentences are counted by updating the count on `(SentenceNode "ANY")`.
; Parses are counted by updating the count on `(ParseNode "ANY")`.
; Words are counted by updating the count on the `WordNode` for that
; word. It is counted with multiplicity: once for each time it occurs
; in a parse.  That is, if a word appears twice in a parse, it is counted
; twice.
;
; Word-pairs show up, and are counted in four different ways. First,
; a count is made if two words appear, left-right ordered, in the same
; sentence. This count is stored in the CountTV for the EvaluationLink
; on (PredicateNode "*-Sentence Word Pair-*").  A second count is
; maintained for this same pair, but including the distance between the
; two words. This is on (SchemaNode "*-Pair Distance-*").  Since
; sentences always start with LEFT-WALL, this can be used to reconstruct
; the typical word-order in a sentence.
;
; Word-pairs are also designated by means of Link Grammar parses of a
; sentence. A Link Grammar parse creates a list of typed links between
; pairs of words in the sentence. Each such link is counted once, for
; each time that it occurs.  These counts are maintained in the CountTV
; on the EvaluationLink for the LinkGrammarRelationshipNode for that
; word-pair.  In addition, a count is maintained of the length of that
; link.
;
; For the initial stages of the langauge-learning project, the parses
; are produced by the "any" langauge parser, which produces random planar
; trees.  This creates a sampling of word-pairs that is different than
; merely having them show up in the same sentence.  That is, a covering
; of a sentence by random trees does not produce the same edge statistics
; as a clique of edges drawn between all words. This is explored further
; in the diary, in a section devoted to this topic.
;
; The Link Grammar parse also produces and reports the disjuncts that were
; used for each word. These are useful in and of themselves; they indicate
; the hubbiness (link-multiplicity) of each word. The disjunct counts are
; maintained on the LgWordCset for a given word.
;
(use-modules (opencog) (opencog nlp) (opencog persist))
(use-modules (srfi srfi-1))

; ---------------------------------------------------------------------

(define (count-one-atom ATM)
"
  count-one-atom ATM -- increment the count by one on ATM, and
  update the SQL database to hold that count.

  This will also automatically fetch the previous count from
  the SQL database, so that counting will work correctly, when
  picking up from a previous point.

  Warning: this is NOT SAFE for distributed processing! That is
  because this does NOT grab the count from the database every time,
  so if some other process updates the database, this will miss that
  update.
"
	(define (incr-one atom)
		; If the atom doesn't yet have a count TV attached to it,
		; then its probably a freshly created atom. Go fetch it
		; from SQL. Otherwise, assume that what we've got here,
		; in the atomspace, is the current copy.  This works if
		; there is only one process updating the counts.
		(if (not (cog-ctv? (cog-tv atom)))
			(fetch-atom atom)) ; get from SQL
		(cog-inc-count! atom 1) ; increment
	)
	(begin
		(incr-one ATM) ; increment the count on ATM
		(store-atom ATM)) ; save to SQL
)

; ---------------------------------------------------------------------
; make-word-sequence -- extract the sequence of words in a parse.
;
; The parser proves a numbered sequence of word-instances, for example:
;
;    (WordSequenceLink
;         (WordInstanceNode "foo@9023e177")
;         (NumberNode "4567"))
;
; This returns the corresponding structures, for words, starting with
; the left-wall at number zero.  Thus, this would return
;
;    (WordSequenceLink
;         (WordNode "foo")
;         (NumberNode "4"))
;
; when the sentence was "this is some foo".
;
; Due to a RelEx bug in parenthesis handling, the `word-inst-get-word`
; function used here can throw an exception. See documentation.
;
(define (make-word-sequence PARSE)

	; Get the scheme-number of the word-sequence number
	(define (get-number word-inst)
		(string->number (cog-name (word-inst-get-number word-inst))))

	; A comparison function, for use as kons in fold
	(define (least word-inst lim)
		(define no (get-number word-inst))
		(if (< no lim) no lim))

	; Get the number of the first word in the sentence (the left-wall)
	(define wall-no (fold least 9e99 (parse-get-words PARSE)))

	; Convert a word-instance sequence number into a word sequence
	; number, starting with LEFT-WALL at zero.
	(define (make-ordered-word word-inst)
		(WordSequenceLink
			(word-inst-get-word word-inst)
			(NumberNode (- (get-number word-inst) wall-no))))

	; Ahhh .. later code will be easier, if we return the list in
	; sequential order. So, define a compare function and sort it.
	(define (get-no seq-lnk)
		(string->number (cog-name (gdr seq-lnk))))

	(sort (map make-ordered-word (parse-get-words PARSE))
		(lambda (wa wb)
			(< (get-no wa) (get-no wb))))
)

; ---------------------------------------------------------------------
; update-word-counts -- update counts for sentences, parses and words,
; for the given list of sentences.
;
; As explained above, the counts on `(SentenceNode "ANY")` and
; `(ParseNode "ANY")` and on `(WordNode "foobar")` are updated.
;
(define (update-word-counts single-sent)
	(define any-sent (SentenceNode "ANY"))
	(define any-parse (ParseNode "ANY"))

	; Due to a RelEx bug in parenthesis handling, the `word-inst-get-word`
	; function can throw an exception. See documentation. Catch the
	; exception, avoid counting if its thrown.
	(define (try-count-one-word word-inst)
		(catch 'wrong-type-arg
			(lambda () (count-one-atom (word-inst-get-word word-inst)))
			(lambda (key . args) #f)))

	(count-one-atom any-sent)
	(map-parses
		(lambda (parse)
			(count-one-atom any-parse)
			(map try-count-one-word (parse-get-words parse)))
		(list single-sent))
)

; ---------------------------------------------------------------------
; update-pair-counts -- count occurances of word-pairs in a parse.
;
; Note that this might throw an exception...
;
; The structures that get created and incremented are of the form
;
;     EvaluationLink
;         PredicateNode "*-Sentence Word Pair-*"
;         ListLink
;             WordNode "lefty"  -- or whatever words these are.
;             WordNode "righty"
;
;     ExecutionLink
;         SchemaNode "*-Pair Distance-*"
;         ListLink
;             WordNode "lefty"
;             WordNode "righty"
;         NumberNode 3
;
; Here, the NumberNode encdes the distance between the words. It is always
; at least one -- i.e. it is the diffference between their ordinals.
;
(define (update-pair-counts PARSE)

	(define pair-pred (PredicateNode "*-Sentence Word Pair-*"))
	(define pair-dist (SchemaNode "*-Pair Distance-*"))

	; Get the scheme-number of the word-sequence number
	(define (get-number word-inst)
		(string->number (cog-name (word-inst-get-number word-inst))))

	; Create and count a word-pair, and the distance.
	(define (count-one-pair left-word right-word)
		(define pare (ListLink left-word right-word))
		(define dist (- (get-number right-word) (get-number left-word)))

		(count-one-atom (EvaluationLink pair-pred pare))
		(count-one-atom (ExecutionLink pair-dist pare (NumberNode dist))))

	; Create pairs from `first`, and each word in the list in `rest`,
	; and increment counts on these pairs.
	(define (count-pairs first rest)
		(if (not (null? rest))
			(begin
				(count-one-pair first (car rest))
				(count-pairs first (cdr rest)))))

	; Iterate over all of the words in the word-list, making pairs.
	(define (make-pairs word-list)
		(if (not (null? word-list))
			(begin
				(count-pairs (car word-list) (cdr word-list))
				(make-pairs (cdr word-list)))))

	; If this function throws, then it will be here, so all counting
	; will be skipped, if any one word fails.
	(define word-seq (make-word-sequence PARSE))

	; What the heck. Go ahead and count these, too.
	(for-each count-one-atom word-seq)

	; Count the pairs, too.
	(make-pairs word-seq)
)

; ---------------------------------------------------------------------
; for-each-lg-link -- loop over all link-grammar links in a sentence.
;
; Each link-grammar link is of the general form:
;
;   EvaluationLink
;      LinkGrammarRelationshipNode "FOO"
;      ListLink
;         WordInstanceNode "word@uuid"
;         WordInstanceNode "bird@uuid"
;
; The PROC is a function to be invoked on each of these.
;
(define (for-each-lg-link PROC SENT)
	(for-each
		(lambda (parse)
			(for-each PROC (parse-get-links parse)))
		(sentence-get-parses SENT))
)

; ---------------------------------------------------------------------
; make-word-link -- create a word-link from a word-instance link
;
; Get the LG word-link relation corresponding to a word-instance LG link
; relation. An LG link is simply a single link-grammar link between two
; words (or two word-instances, when working with a single sentence).
;
; This function simply strips off the unique word-ids from each word.
; For example, given this as input:
;
;   EvaluationLink
;      LinkGrammarRelationshipNode "FOO"
;      ListLink
;         WordInstanceNode "word@uuid"
;         WordInstanceNode "bird@uuid"
;
; this creates and returns this:
;
;   EvaluationLink
;      LinkGrammarRelationshipNode "FOO" -- gar
;      ListLink                          -- gdr
;         WordNode "word"                -- gadr
;         WordNode "bird"                -- gddr
;
(define (make-word-link lg-rel-inst)
	(let (
			(rel-node (gar lg-rel-inst))
			(w-left  (word-inst-get-word (gadr lg-rel-inst)))
			(w-right (word-inst-get-word (gddr lg-rel-inst)))
		)
		(EvaluationLink rel-node (ListLink w-left w-right))
	)
)

; ---------------------------------------------------------------------
; make-word-cset -- create a word-cset from a word-instance cset
;
; A cset is a link-grammar connector set. This takes, as input
; a cset that is attached to a word instance, and creates the
; corresponding cset attached to a word. Basically, it just strips
; off the UUID from the word-instance.
;
; For example, given this input:
;
;   LgWordCset
;      WordInstanceNode "foobar@1233456"
;      LgAnd ...
;
; this creates and returns this:
;
;   LgWordCset
;      WordNode "foobar"  -- gar
;      LgAnd ...          -- gdr
;
(define (make-word-cset CSET-INST)
	(LgWordCset
		(word-inst-get-word (gar CSET-INST))
		(gdr CSET-INST))
)

; ---------------------------------------------------------------------
; update-link-counts -- Increment link counts
;
; This routine updates link counts in the database. The algo is trite:
; fetch the LG link from SQL, increment the attached CountTruthValue,
; and save back to SQL.

(define (update-link-counts single-sent)

	; Due to a RelEx bug, `make-word-link` can throw an exception.  See
	; the documentation for `word-inst-get-word` for details. Look for
	; this exception, and avoid it, if possible.
	(define (try-count-one-link link)
		(catch 'wrong-type-arg
			(lambda () (count-one-atom (make-word-link link)))
			(lambda (key . args) #f)))

	(for-each-lg-link try-count-one-link (list single-sent))
)

; ---------------------------------------------------------------------
; update-disjunct-counts -- Increment disjunct counts
;
; Just like the above, but for the disjuncts.

(define (update-disjunct-counts single-sent)

	(define (try-count-one-cset CSET)
		(catch 'wrong-type-arg
			(lambda () (count-one-atom (make-word-cset CSET)))
			(lambda (key . args) #f)))

	(map-parses
		(lambda (parse)
			(map (lambda (wi) (try-count-one-cset (word-inst-get-cset wi)))
				(parse-get-words parse)))
		(list single-sent))
)

; ---------------------------------------------------------------------
;
; Stupid monitoring utility that can be used to monitor how processing
; is going so far. It counts how many sentences have been processed so
; far. If called with a null argument, it increments the count; else it
; just prints the count.
(define-public monitor-rate
	(let ((mtx (make-mutex))
			(cnt 0)
			(start-time (- (current-time) 0.000001)))
		(lambda (msg)
			(if (null? msg)
				(begin
					(lock-mutex mtx)
					(set! cnt (+ cnt 1))
					(unlock-mutex mtx))
				(format #t "~A cnt=~A rate=~A\n" msg cnt
					(/ cnt (- (current-time) start-time))))
		)))

; ---------------------------------------------------------------------
(define-public (observe-text plain-text)
"
 observe-text -- update word and word-pair counts by observing raw text.

 This is the first part of the learning algo: simply count the words
 and word-pairs oberved in incoming text. This takes in raw text, gets
 it parsed, and then updates the counts for the observed words and word
 pairs.
"
	; Loop -- process any that we find. This will typically race
	; against other threads, but I think that's OK.
	(define (process-sents)
		(let ((sent (get-one-new-sentence)))
			(if (null? sent) '()
				(begin
					(update-word-counts sent)
					(update-link-counts sent)
					(update-disjunct-counts sent)
					(delete-sentence sent)
					(monitor-rate '())
					(process-sents)))))

	(relex-parse plain-text) ;; send plain-text to server
	(process-sents)
	(gc) ;; need agressive gc to keep RAM under control.
)

; ---------------------------------------------------------------------
;
; Some notes for hand-testing the code up above:
;
; (sql-open "postgres:///en_pairs?user=linas")
; (use-relex-server "127.0.0.1" 4445)
;
; (define (prt x) (display x))
;
; (relex-parse "this is")
; (get-new-parsed-sentences)
;
; (for-each-lg-link prt (get-new-parsed-sentences))
;
; (for-each-lg-link (lambda (x) (prt (make-word-link x)))
;    (get-new-parsed-sentences))
;
; (for-each-lg-link (lambda (x) (prt (gddr (make-word-link x))))
;    (get-new-parsed-sentences))
;
; (for-each-lg-link (lambda (x) (cog-inc-count! (make-word-link x) 1))
;    (get-new-parsed-sentences))
;
; (observe-text "abcccccccccc  defffffffffffffffff")
