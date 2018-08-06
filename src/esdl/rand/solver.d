module esdl.rand.solver;
import esdl.rand.obdd;
import std.container.array;

import esdl.rand.base: CstVarPrim, CstStage, CstBddExpr,// , CstValAllocator
  CstDomain, CstEquation, CstBlock;
import esdl.rand.misc;


abstract class _esdl__ConstraintBase: _esdl__Norand
{
  this(_esdl__SolverRoot eng, string name, string constraint, uint index) {
    _cstEng = eng;
    _name = name;
    _constraint = constraint;
    _index = index;
  }
  immutable @rand!false string _constraint;
  protected @rand!false bool _enabled = true;
  protected @rand!false _esdl__SolverRoot _cstEng;
  protected @rand!false string _name;
  // index in the constraint Database
  protected @rand!false uint _index;

  bool isEnabled() {
    return _enabled;
  }

  void enable() {
    _enabled = true;
  }

  void disable() {
    _enabled = false;
  }

  BDD getConstraintBDD() {
    BDD retval = _cstEng._esdl__buddy.one();
    return retval;
  }

  string name() {
    return _name;
  }

  abstract CstBlock getCstExpr();
}

static char[] constraintXlate(string CST, string FILE, size_t LINE, string NAME="") {
  import esdl.rand.cstx;
  CstParser parser = CstParser(CST, FILE, LINE);
  return parser.translate(NAME);
}

abstract class Constraint(string CONSTRAINT, string FILE=__FILE__, size_t LINE=__LINE__)
  : _esdl__ConstraintBase
{
  this(_esdl__SolverRoot eng, string name, uint index) {
    super(eng, name, CONSTRAINT, index);
  }
};


template _esdl__baseHasRandomization(T) {
  static if(is(T B == super)
	    && is(B[0] == class)) {
    alias U = B[0];
    static if(__traits(compiles, U._esdl__hasRandomization)) {
      enum bool _esdl__baseHasRandomization = true;
    }
    else {
      enum bool _esdl__baseHasRandomization = _esdl__baseHasRandomization!U;
    }
  }
  else {
    enum bool _esdl__baseHasRandomization = false;
  }
}

abstract class _esdl__SolverRoot {
  // Keep a list of constraints in the class
  _esdl__ConstraintBase[] _esdl__cstsList;
  _esdl__ConstraintBase _esdl__cstWith;
  bool _esdl__cstWithChanged;

  // ParseTree parseList[];
  CstVarPrim[] _esdl__randsList;
  _esdl__RandGen _esdl__rGen;

  _esdl__RandGen _esdl__getRandGen() {
    return _esdl__rGen;
  }

  Buddy _esdl__buddy;

  Array!uint _domains;		// indexes of domains

  CstDomain[] _cstDomains;

  uint _domIndex = 0;
  
  // compositional parent -- not inheritance based
  _esdl__SolverRoot _parent = null;

  _esdl__SolverRoot getSolverRoot() {
    if (_parent is null || _parent is this) {
      return this;
    }
    else {
      return _parent.getSolverRoot();
    }
  }
	
  bool _esdl__isSeeded = false;
  uint _esdl__seed;

  CstBlock _esdl__cstEqns;

  CstStage[] savedStages;

  uint getRandomSeed() {
    return _esdl__seed;
  }

  void seedRandom(uint seed) {
    _esdl__seed = seed;
    _esdl__rGen.seed(seed);    
  }
  
  this(uint seed, bool isSeeded, string name,
       _esdl__SolverRoot parent) {
    import std.random: Random, uniform;
    debug(NOCONSTRAINTS) {
      assert(false, "Constraint engine started");
    }
    _esdl__isSeeded = isSeeded;
    if (isSeeded is true) {
      _esdl__seed = seed;
    }
    else {
      import esdl.base.core: Procedure;
      auto proc = Procedure.self;
      if (proc !is null) {
	Random procRgen = proc.getRandGen();
	_esdl__seed = uniform!(uint)(procRgen);
      }
      else {
	// no active simulation -- use global rand generator
	_esdl__seed = uniform!(uint)();
      }
    }
    _esdl__rGen = new _esdl__RandGen(_esdl__seed);

    if(parent is null) {
      _esdl__buddy = new Buddy(400, 400);
      _esdl__cstEqns = new CstBlock();
    }
    else {
      _parent = parent;
    }
  }

  ~this() {
    _esdl__cstsList.length   = 0;
    _esdl__cstWith           = null;
    _esdl__cstWithChanged    = true;
    _esdl__randsList.length  = 0;
  }

  // overridden by Randomization mixin -- see meta.d
  void _esdl__initRands() {}
  void _esdl__initCsts() {}
  void _esdl__doRandomize(_esdl__RandGen randGen) {}

  void solve() { // (T)(T t) {
    // writeln("Solving BDD for number of constraints = ", _esdl__cstsList.length);
    uint lap = 0;
    // if (_domains.length is 0 // || _esdl__cstWithChanged is true
    // 	) {
    if (_esdl__cstEqns.isEmpty || _esdl__cstWithChanged is true) {
      initEqns();
    }
    //initDomains();

    //   // _esdl__cstEqns._esdl__reset(); // start empty
    
    //   // take all the constraints -- even if disabled
    //   // if (_esdl__cstEqns.isEmpty()) {
    //   // foreach(ref _esdl__ConstraintBase cst; _esdl__cstsList) {
    //   // 	_esdl__cstEqns ~= cst.getCstExpr();
    //   // }
    //   // if(_esdl__cstWith !is null) {
    //   // 	_esdl__cstEqns ~= _esdl__cstWith.getCstExpr();
    //   // }
    //   //}

    // }

    // CstValAllocator.mark();

    CstStage[] unsolvedStages;

    int stageIdx=0;
    CstEquation[] unrolledEqns = _esdl__cstEqns._eqns;	// unstaged Expressions -- all
    CstEquation[] toResolveEqns;   			// need resolution wrt LAP logic
    CstEquation[] unresolvedEqns;			// need resolution wrt LAP logic
    
    // import std.stdio;
    // writeln("There are ", unrolledEqns.length, " number of unsolved expressions");
    // writeln("There are ", _cstDomains.length, " number of domains");

    while(unrolledEqns.length > 0 || unsolvedStages.length > 0) {
      lap += 1;

      CstStage[] cstStages = unsolvedStages;
      unsolvedStages.length = 0;

      CstEquation[] cstExprs = unrolledEqns;
      unrolledEqns.length = 0;
      toResolveEqns = unresolvedEqns;
      unresolvedEqns.length = 0;

      CstBddExpr[] uwExprs;	// unwound expressions

      // unroll all the unrollable expressions
      foreach(expr; cstExprs) {
	// import std.stdio;
	// writeln("Unrolling: ", expr.name());
	// auto unwound = expr.unroll();
	// for (size_t i=0; i!=unwound.length; ++i) {
	//   writeln("Unwound as: ", unwound[i].name());
	// }
	expr.unroll(lap, unrolledEqns, unrolledEqns, toResolveEqns// uwExprs
		    );
      }

      // foreach(expr; uwExprs) {
      // 	// if(expr.itrVars().length is 0) {
      // 	if(expr.hasUnresolvedIdx()) {
      // 	  import std.stdio;
      // 	  writeln("Adding expression ", expr.name(), " to unresolved");
      // 	  expr.resolveLap(lap);
      // 	  unrolledEqns ~= expr;
      // 	}
      // 	// else {
      // 	//   toResolveEqns ~= expr;
      // 	// }
      // }

      foreach (eqn; toResolveEqns) {
	// import std.stdio;
	uint elap = eqn.getExpr().resolveLap();
	// writefln("Unroll Lap of the eqn %s is %s", eqn.name() , lap);
	if (elap == lap) {
	  unresolvedEqns ~= eqn;
	}
	else {
	  // import std.stdio;
	  // writeln("Adding eqn ", eqn.name(), " to stage");
	  addCstStage(eqn, cstStages);
	}
      }

      foreach(stage; cstStages) {
	if(stage !is null) {
	  solveStage(stage, stageIdx);
	}
	else {
	  // assert(stage._domVars.length !is 0);
	  unsolvedStages ~= stage;
	}
      }
      
    }

    // CstValAllocator.reset();
    
  }

  void solveStage(CstStage stage, ref int stageIdx) {
    // import std.stdio;
    
    import std.conv;
    CstEquation[] allEqns = stage._bddEqns;
    CstEquation[] eqns;
    // writeln("Here in solveStage: ", stageIdx);

    foreach (eqn; allEqns) {
      if (! eqn.getExpr().cstExprIsNop()) {
	eqns ~= eqn;
      }
    }

    if (eqns.length == 0) {
      // import std.stdio;
      // writeln("Only NOP expressions!");
      foreach(vec; stage._domVars) {
	// writeln("Randomizing: ", vec.name());
	vec._esdl__doRandomize(this._esdl__rGen, stage);
      }
      stage.id(stageIdx);
      stageIdx += 1;
      return;
    }
    // initialize the bdd vectors
    BDD solveBDD = _esdl__buddy.one();
    foreach(vec; stage._domVars) {
      if(vec.stage is stage) {
	if(vec.bddvec(_esdl__buddy).isNull()) {
	  vec.bddvec(_esdl__buddy).buildVec(vec.domIndex, vec.signed);
	}
      }
    }

    // make the bdd tree
    bool refreshed = false;
    foreach (eqn; eqns) {
      // import std.stdio;
      refreshed |= eqn.getExpr().refresh(stage, _esdl__buddy);
      // writeln("refreshed: ", refreshed);
    }
    // import std.stdio;
    // writeln("Saved Stages: ", savedStages.length);
    // writeln("Saved Stages Index: ", stageIdx);
    // if (savedStages.length > stageIdx) {
    //   foreach (eqn; savedStages[stageIdx]._bddEqns) {
    // 	writeln("saved: ", eqn.name());
    //   }
    //   writeln("Comparison: ", savedStages[stageIdx]._bddEqns[0] == stage._bddEqns[0]);
    // }
    // foreach (eqn; stage._bddEqns) {
    //   writeln("saved: ", eqn.name());
    // }
    if ((! refreshed) &&
	savedStages.length > stageIdx &&
	savedStages[stageIdx]._bddEqns == stage._bddEqns) {
      // import std.stdio;
      // writeln("Reusing previous BDD solution");
      stage._solveBDD = savedStages[stageIdx]._solveBDD;
      stage._bddDist = savedStages[stageIdx]._bddDist;
      solveBDD = stage._solveBDD;
    }
    else {
      foreach(vec; stage._domVars) {
	BDD primBdd = vec.getPrimBdd(_esdl__buddy);
	if(! primBdd.isOne()) {
	  solveBDD = solveBDD & primBdd;
	}
      }
      foreach(eqn; eqns) {
	// import std.stdio;
	// writeln("here too for eqns: ", eqn.name);
	solveBDD = solveBDD & eqn.getExpr().getBDD(stage, _esdl__buddy);
	// writeln(eqn.name());
      }
      stage._solveBDD = solveBDD;
      stage._bddDist.clear();
      solveBDD.satDist(stage._bddDist);
    }


    // import std.stdio;
    // writeln("bddDist: ", stage._bddDist);
    
    auto solution = solveBDD.randSatOne(this._esdl__rGen.get(),
					stage._bddDist);
    auto solVecs = solution.toVector();

    byte[] bits;
    if(solVecs.length != 0) {
      bits = solVecs[0];
    }

    foreach (vec; stage._domVars) {
      ulong v;
      enum WORDSIZE = 8 * v.sizeof;
      auto bitvals = solveBDD.getIndices(vec.domIndex);
      foreach (uint i, ref j; bitvals) {
	uint pos = i % WORDSIZE;
	uint word = i / WORDSIZE;
	if (bits.length == 0 || bits[j] == -1) {
	  v = v + ((cast(size_t) _esdl__rGen.flip()) << pos);
	}
	else if (bits[j] == 1) {
	  v = v + ((cast(ulong) 1) << pos);
	}
	if (pos == WORDSIZE - 1 || i == bitvals.length - 1) {
	  vec.collate(v, word);
	  v = 0;
	}
      }
    }
    stage.id(stageIdx);

    // save for future reference
    while (savedStages.length <= stageIdx) {
      savedStages ~= new CstStage();
    }
    assert(savedStages[stageIdx] !is stage);

    savedStages[stageIdx].copyFrom(stage);

    stageIdx += 1;
  }

  // list of constraint eqns to solve at a given stage
  // void addCstStage(CstVarPrim prim, ref CstStage[] cstStages) {
  //   assert (prim !is null);
  //   if(prim.stage() is null) {
  //     CstStage stage = new CstStage();
  //     cstStages ~= stage;
  //     prim.stage = stage;
  //     stage._domVars ~= prim;
  //     // cstStages[stage]._domVars ~= prim;
  //   }
  // }

  void addCstStage(CstEquation eqn, ref CstStage[] cstStages) {
    // uint stage = cast(uint) _cstStages.length;
    auto vecs = eqn.getExpr().getRndDomains(true);
    // import std.stdio;
    // foreach (vec; vecs) writeln(vec.name());
    CstStage stage;
    foreach (ref vec; vecs) {
      if (! vec.solved()) {
	assert(vec !is null);
	if (vec.stage() is null) {
	  // import std.stdio;
	  // writeln("new stage for vec: ", vec.name());
	  // writeln("eqn: ", eqn.name());
	  if (stage is null) {
	    stage = new CstStage();
	    cstStages ~= stage;
	  }
	  vec.stage = stage;
	  stage._domVars ~= vec;
	  // cstStages[stage]._domVars ~= vec;
	}
	if (stage !is vec.stage()) { // need to merge stages
	  // import std.stdio;
	  // writeln("merging");
	  mergeCstStages(stage, vec.stage(), cstStages);
	  stage = vec.stage();
	}
      }
    }
    if (stage is null) {
      stage = new CstStage();
      cstStages ~= stage;
    }
    // import std.stdio;
    // writeln(eqn.name());
    // assert (stage !is null);
    // writeln(stage._bddEqns.length);
    stage._bddEqns ~= eqn;
  }

  void mergeCstStages(CstStage fromStage, CstStage toStage,
		      ref CstStage[] cstStages) {
    if(fromStage is null) {
      // fromStage has not been created yet
      return;
    }
    foreach(ref vec; fromStage._domVars) {
      vec.stage = toStage;
    }
    toStage._domVars ~= fromStage._domVars;
    toStage._bddEqns ~= fromStage._bddEqns;
    if(cstStages[$-1] is fromStage) {
      cstStages.length -= 1;
    }
    else {
      fromStage._domVars.length = 0;
      fromStage._bddEqns.length = 0;
    }
  }

  void initEqns() {
    CstDomain[] unresolvedIdxs;

    _esdl__cstEqns._esdl__reset(); // start empty

    // take all the constraints -- even if disabled
    foreach(ref _esdl__ConstraintBase cst; _esdl__cstsList) {
      _esdl__cstEqns ~= cst.getCstExpr();
    }

    if(_esdl__cstWith !is null) {
      _esdl__cstEqns ~= _esdl__cstWith.getCstExpr();
    }

    foreach (eqn; _esdl__cstEqns._eqns) {
      unresolvedIdxs ~= eqn.getExpr().unresolvedIdxs();
    }

    foreach(idx; unresolvedIdxs) {
      _esdl__cstEqns ~= new CstEquation(idx.getNopBddExpr());
      // import std.stdio;
      // writeln(idx.name());
      // writeln(idx.getNopBddExpr().name());
    }
    
  }
  
  void initDomains() { // (T)(T t) {
    // int[] domList;
    

    // foreach (dom; _cstDomains) dom.reset();
    
    // this._domIndex = 0;
    // _domains.length = 0;
    // _cstDomains.length = 0;
    
    // _esdl__buddy.clearAllDomains();

    
    // foreach(stmt; _esdl__cstEqns._exprs) {
    //   addDomains(stmt.getRndDomains(false));
    // }
  }

  void addDomain(CstDomain domain) {
    // import std.stdio;
    // writeln("Adding domain: ", domain.name());
    _cstDomains ~= domain;
    useBuddy(_esdl__buddy);
    domain.domIndex = this._domIndex++;
    _domains ~= _esdl__buddy.extDomVec(domain.bitcount);
  }

  // void addDomains(CstDomain[] domains) {
  //   uint[] domList;

  //   // foreach (vec; domains) {
  //   //   assert(vec.domIndex == uint.max);
  //   //   // vec.domIndex = uint.max;
  //   // }

  //   foreach(vec; domains) {
  //     if(vec.domIndex == uint.max) {
  // 	vec.domIndex = this._domIndex++;
  // 	domList ~= vec.bitcount;
  //     }
  //   }
  //   _domains ~= _esdl__buddy.extDomVec(domList);
  // }

  void printSolution() {
    // import std.stdio;
    // writeln("There are solutions: ", _theBDD.satCount());
    // writeln("Distribution: ", dist);
    // auto randSol = _theBDD.randSat(randGen, dist);
    // auto solution = _theBDD.fullSatOne();
    // solution.printSetWith_Domains();
  }
}
