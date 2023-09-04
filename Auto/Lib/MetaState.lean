import Lean
import Auto.Lib.MonadUtils
import Auto.Lib.MetaExtra
open Lean

namespace Auto.MetaState

structure State extends Meta.State, Meta.Context

structure SavedState where
  core       : Core.State
  meta       : State

abbrev MetaStateM := StateRefT State CoreM

@[always_inline]
instance : Monad MetaStateM := let i := inferInstanceAs (Monad MetaStateM); { pure := i.pure, bind := i.bind }

instance : MonadLCtx MetaStateM where
  getLCtx := return (← get).toContext.lctx

instance : MonadMCtx MetaStateM where
  getMCtx      := return (← get).toState.mctx
  modifyMCtx f := modify (fun s => {s with mctx := f s.mctx})

instance : MonadEnv MetaStateM where
  getEnv      := return (← getThe Core.State).env
  modifyEnv f := do modifyThe Core.State fun s => { s with env := f s.env, cache := {} }; modify fun s => { s with cache := {} }

instance : AddMessageContext MetaStateM where
  addMessageContext := addMessageContextFull

protected def saveState : MetaStateM SavedState :=
  return { core := (← getThe Core.State), meta := (← get) }

def SavedState.restore (b : SavedState) : MetaStateM Unit := do
  Core.restore b.core
  modify fun s => { s with mctx := b.meta.mctx, zetaFVarIds := b.meta.zetaFVarIds, postponed := b.meta.postponed }

instance : MonadBacktrack SavedState MetaStateM where
  saveState      := MetaState.saveState
  restoreState s := s.restore

#genMonadState MetaStateM

def runMetaM (n : MetaM α) : MetaStateM α := do
  let s ← get
  let (ret, s') ← n.run s.toContext s.toState
  setToState s'
  return ret

def runWithIntroducedFVarsImp (m : MetaStateM (Array FVarId × α)) (k : α → MetaM β) : MetaM β := do
  let s ← get
  let ctx ← read
  let ((fvars, a), sc') ← m.run ⟨s, ctx⟩
  Meta.runWithFVars sc'.lctx fvars (k a)

def runWithIntroducedFVars [MonadControlT MetaM n] [Monad n]
  (m : MetaStateM (Array FVarId × α)) (k : α → n β) : n β :=
  Meta.map1MetaM (fun k => runWithIntroducedFVarsImp m k) k

def inferType (e : Expr) : MetaStateM Expr := runMetaM (Meta.inferType e)

def isDefEq (t s : Expr) : MetaStateM Bool := runMetaM (Meta.isDefEq t s)

def isLevelDefEq (u v : Level) : MetaStateM Bool := runMetaM (Meta.isLevelDefEq u v)

def mkLocalDecl (fvarId : FVarId) (userName : Name) (type : Expr)
  (bi : BinderInfo := BinderInfo.default) (kind : LocalDeclKind := LocalDeclKind.default) : MetaStateM Unit := do
  let ctx ← getToContext
  let lctx := ctx.lctx
  setToContext ({ctx with lctx := lctx.mkLocalDecl fvarId userName type bi kind})

def mkLetDecl (fvarId : FVarId) (userName : Name) (type value : Expr)
  (nonDep : Bool := false) (kind : LocalDeclKind := default) : MetaStateM Unit := do
  let ctx ← getToContext
  let lctx := ctx.lctx
  setToContext ({ctx with lctx := lctx.mkLetDecl fvarId userName type value nonDep kind})

private def withNewLocalInstance (className : Name) (fvar : Expr) : MetaStateM Unit := do
  let localDecl ← runMetaM <| Meta.getFVarLocalDecl fvar
  if !localDecl.isImplementationDetail then
    let ctx ← getToContext
    setToContext ({ ctx with localInstances := ctx.localInstances.push { className := className, fvar := fvar } })

private def withNewFVar (fvar fvarType : Expr) : MetaStateM Unit := do
  if let some c ← runMetaM <| Meta.isClass? fvarType then
    withNewLocalInstance c fvar

def withLocalDecl (n : Name) (bi : BinderInfo) (type : Expr) (kind : LocalDeclKind) : MetaStateM FVarId := do
  let fvarId ← mkFreshFVarId
  mkLocalDecl fvarId n type bi kind
  let fvar := mkFVar fvarId
  withNewFVar fvar type
  return fvarId

def withLetDecl (n : Name) (type : Expr) (val : Expr) (kind : LocalDeclKind) : MetaStateM FVarId := do
  let fvarId ← mkFreshFVarId
  mkLetDecl fvarId n type val (nonDep := false) kind
  let fvar := mkFVar fvarId
  withNewFVar fvar type
  return fvarId

end Auto.MetaState