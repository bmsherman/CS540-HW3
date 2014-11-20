module Compile where

import AST

import Control.Applicative ((<$>), (<*>))
import Control.Monad (zipWithM)
import Control.Monad.Trans.State (State, get, put, evalState, gets)

import qualified Data.Bits as B
import Data.Int (Int32)
import Data.List (intercalate, foldl')

import qualified Data.Map as M
import Data.Map (Map)
import Data.Maybe (catMaybes, fromMaybe)
import qualified Data.Set as S
import Data.Set (Set)

data CExpr v = CInt Int32
  | CStr String String
  | CVar v
  | CAp String [v]
  | CCase v [Production (CExpr v)]
  | CLet v (CExpr v) (CExpr v)
  deriving Show

varsInExp :: Expr -> Set String
varsInExp e = case e of
  ELet (TypedIdent v _) e1 e2 -> 
    S.insert v (varsInExp e1 `S.union` varsInExp e2)
  ECase e prods -> varsInExp e `S.union` S.fromList
    [ t | Production (Pattern _ terms) _ <- prods, t <- terms ]
  EAp _ _ es -> S.unions (map varsInExp es)
  Typed e _ -> varsInExp e
  _ -> S.empty

toCExpr :: Set String -> Expr -> CExpr String
toCExpr usedVars e = evalState (f e) (0, usedVars `S.union` varsInExp e) 
  where
  f e = case e of
    EInt i -> return $ CInt i
    EStr s -> do
      (i, vs) <- get
      let i' = i + 1
      put (i', vs)
      return $ CStr ("str" ++ show i') s
    EVar v -> return $ CVar v
    EAp _ func es -> do
      (vs, lets) <- unzip <$> zipWithM funcArgs [1..] es
      case func of 
        "seq" -> head lets <$> f (es !! 1) -- special inlining for seq
        _ -> return $ foldr (.) id lets (CAp func vs)
    ECase e prods -> do
      v <- newV "scrut"
      e' <- f e
      prods' <- mapM doProd prods
      return $ CLet v e' (CCase v prods')
    ELet (TypedIdent v _) e1 e2 ->
      CLet v <$> f e1 <*> f e2
    Typed e _ -> f e
  funcArgs i assn = do
    v <- newV ("arg" ++ show i)
    assn' <- f assn
    return (v, CLet v assn')
  doProd (Production p e) = fmap (Production p) (f e)
  newV str = do
    (i, vs) <- get
    let str' : _ = [ n | n <- map (str ++) ( "" : map show [ 0 :: Int .. ] )
                       , not (S.member n vs) ]
    put (i, S.insert str' vs) >> return str'

data RegGlob = RGR Register | RGG String deriving Eq

instance Show RegGlob where
  show (RGR reg) = "*" ++ show reg
  show (RGG global) = global

data Instr = 
    BinOp String Oper Oper
  | UnOp String Oper
  | Call RegGlob
  | Jump String RegGlob
  | Syscall
  | Ret

  | Ascii String
  | Asciz String
  | Quad Int32
  deriving (Eq, Show)

mov = BinOp "mov"
cmp = BinOp "cmp"
movq = BinOp "movq"
clear oper = BinOp "xor" oper oper
add = BinOp "add"
imul = BinOp "imul"
push = UnOp "push"
pop = UnOp "pop"
idiv = UnOp "idiv"

data CDecl = Label String [Instr] deriving (Eq, Show)

data Register = 
    RAX | RCX | RDX
  | R8 | R9 | R10 | R11 | R12 | R13 | R14 | R15
  | RDI | RSI
  | RSP
  deriving (Eq, Enum)

instance Show Register where
  show x = ("%" ++) $ case x of
    RAX -> "rax"
    RCX -> "rcx"
    RDX -> "rdx"
    R8 -> "r8"
    R9 -> "r9"
    R10 -> "r10"
    R11 -> "r11"
    R12 -> "r12"
    R13 -> "r13"
    R14 -> "r14"
    R15 -> "r15"
    RDI -> "rdi"
    RSI -> "rsi"
    RSP -> "rsp"

data Oper = Global String
  | Imm Int32 | Reg Register | Mem Int Register 
  deriving (Eq, Show)

printOper :: Oper -> String
printOper o = case o of
  Imm i -> "$" ++ show i
  Global name -> "$" ++ name
  Reg reg -> show reg
  Mem i reg -> (if i == 0 then "" else show i) ++ "(" ++ show reg ++ ")"

printInstr :: Instr -> String
printInstr i = case i of
  BinOp s o1 o2 -> unop s o1 ++ ", " ++ printOper o2
  Call rg -> "call " ++ show rg
  Jump name rg -> name ++ " " ++ show rg
  Syscall -> "syscall"
  UnOp s o -> unop s o
  Ret -> "ret"
  Ascii str -> ".ascii \"" ++ str ++ "\""
  Asciz str -> ".asciz \"" ++ str ++ "\""
  Quad i -> ".quad " ++ show i
  where
  unop str a = str ++ " " ++ printOper a 

printCDecl :: CDecl -> String
printCDecl (Label name instrs) = name ++ ":\n" ++ 
  intercalate "\n" (map (("  " ++) . printInstr) instrs)

constructor :: String -> Int -> [CDecl]
constructor name 0 = 
  [ Label (name ++ ".hash") [Quad (hash name)]
  , Label name [ movq (Global (name ++ ".hash")) (Reg RAX), Ret ]
  ]
constructor name arity = [Label name $ mkFunc $ \xs -> 
  let xs' = take arity xs in
  [ push (Reg x) | x <- reverse xs' ]
  ++ callFunc "malloc" [Imm (8 * (fromIntegral arity + 1))] (\addr ->
  movq (Imm (hash name)) (Mem 0 addr) : 
    [ pop (Mem (8 * i) addr) | i <- take arity [1..] ]
  )]

hash :: String -> Int32
hash = foldl' (\h c -> 33 * h `B.xor` fromIntegral (fromEnum c)) 5381

func :: String -> FuncDefn -> [CDecl]
func fname (FuncDefn args _ expr) = flip evalState initState $ do
  loads <- zipWithM newVar args' (map Reg funcRegs)
  (decls, instrs) <- ff Nothing fname expr' 
  return (Label fname (loads ++ instrs) : decls)
  where
  branchState f = do state <- get; x <- f; put state; return x
  ret tailc instrs = do
     cleanup <- mkCleanup initStackSize
     return (instrs ++ cleanup ++ [retInstr])
    where
    (initStackSize, retInstr) = case tailc of
      Nothing -> (0, Ret)
      Just (retAddr, ss) -> (ss, Jump "jmp" retAddr)
  ff tailc lbl e = case e of
    CInt i -> (,) [] <$> ret tailc [mov (Imm i) (Reg RAX)]
    CStr lab str -> let lbl' = lbl ++ lab in
      (,) [Label lbl' [Ascii (str ++ "\\0")] ] <$>
        ret tailc [mov (Global lbl') (Reg RAX)]
    CVar v -> do
      oper <- getVar v
      (,) [] <$> ret tailc [mov oper (Reg RAX)]
    CLet v (CVar v1) e -> dupVar v v1 >> ff tailc lbl e
    CLet v e1 e2 -> do
      let lblL = lbl ++ ".L"
      ss <- gets stackSize
      let tailc' = Just (RGG lblL, ss)
      (decls, instrs) <- branchState $ ff tailc' (lbl ++ ".l") e1
      load <- newVar v (Reg RAX)
      (decls2, instrs2) <- ff tailc lblL e2
      return (Label lblL (load : instrs2) : decls ++ decls2
             , instrs)
    CAp f xs -> do
      moper <- mGetVar f
      let (loadF, rgF) = case moper of
            Nothing -> ([], RGG (toSymbolName f))
            Just oper -> ([movq oper (Reg R12)], RGR R12)
      argOpers <- mapM getVar xs
      let loadArgs = zipWith mov argOpers (map Reg funcRegs)
      (,) [] <$> case tailc of
        Nothing -> ret (Just (rgF, 0)) (loadArgs ++ loadF)
        Just _ -> ret tailc (loadArgs ++ loadF ++ [Call rgF])
    CCase v prods -> do
      oper <- getVar v
      (decls, instrs) <- unzip <$> mapM (mkCase tailc lbl) prods
      return (errorMsg : concat decls, 
        [ mov oper (Reg RAX) ] ++ concat instrs ++ 
        callFunc "error" [Global errorLbl] (const [])
        )
  
  mkCase tailc lbl (Production (Pattern constr vars) expr) = branchState $ do
    loads <- zipWithM f [1..] vars
    (decls, instrs) <- ff tailc lbl' expr
    instrs' <- ret tailc (loads ++ instrs)
    return ( Label lbl' instrs' : decls ,
      conditionalCall )
    where
    conditionalCall = [ BinOp "cmpl" (Imm (hash constr)) (Mem 0 RAX)
           , Jump "je" (RGG lbl') ]
    lbl' = lbl ++ "." ++ constr
    f i v = newVar v (Mem (8 * i) RAX)

  errorLbl = fname ++ ".err"
  errorMsg = Label errorLbl [ Ascii ("Pattern matching failure in function '"
    ++ fname ++ "'.\\0") ]
  args' = [ n | TypedIdent n _ <- args ]
  expr' = toCExpr (S.fromList args') expr

intOp :: (Oper -> Oper -> Instr) -> [Instr]
intOp op = mkFunc $ \(x:y:_) ->
  [ mov (Reg x) (Reg RAX)
  , op (Reg y) (Reg RAX)
  ]

cmpOp :: String -> [Instr]
cmpOp trueCond = mkFunc $ \(x:y:_) ->
    [ cmp (Reg y) (Reg x)
    , Jump ("j" ++ trueCond) (RGG "True")
    , mov (Global "False.hash") (Reg RAX)
    ]

intOps :: [CDecl]
intOps = negOp : [ Label (toSymbolName x) (intOp y)
  | (x, y) <- [ ("plus", add), ("minus", BinOp "sub"), ("times", imul) ]
  ] where
  negOp = Label (toSymbolName "negate") $ mkFunc $ \(x:_) ->
    [ UnOp "neg" (Reg x), mov (Reg x) (Reg RAX) ]

cmpOps :: [CDecl]
cmpOps = [ Label (toSymbolName (x ++ "Int")) (cmpOp y)
  | (x, y) <- [ ("lt", "l"), ("lte", "le"), ("eq", "e")
              , ("gt", "ge"), ("gte", "g") ]
  ]

divOp :: CDecl
divOp = Label (toSymbolName "div") $ mkFunc $ \(x:y:_) ->
  [ clear (Reg RDX)
  , mov (Reg x) (Reg RAX)
  , mov (Reg y) (Reg RSI)
  , idiv (Reg RSI)
  , Ret ]

data CompileState = CompileState
  { vars :: !(Map String Oper)
  , stackSize :: !Int
  }

mkCleanup :: Int -> Compile [Instr]
mkCleanup init = do
  fin <- gets stackSize
  let i = fin - init
  return [ add (Imm (8 * fromIntegral i)) (Reg RSP) | i > 0 ]

initState :: CompileState
initState = CompileState M.empty 0

dupVar :: String -> String -> Compile ()
dupVar new old = do
  CompileState vars stacksize <- get
  oper <- getVar old
  put (CompileState (M.insert new oper vars) stacksize)
  
  

newVar :: String -> Oper -> Compile Instr
newVar n oldOper = do
  CompileState vars stackSize <- get
  let stackSize' = stackSize + 1
  let oper = Mem 0 RSP
  put (CompileState (M.insert n oper (M.map f vars)) stackSize')
  return (push oldOper)
  where
  f (Mem i RSP) = Mem (8 + i) RSP
  f x = x

mGetVar :: String -> Compile (Maybe Oper)
mGetVar n = fmap (M.lookup n . vars) get

getVar :: String -> Compile Oper
getVar n = fromMaybe (Global n) <$> mGetVar n

type Compile = State CompileState

funcRegs :: [Register]
funcRegs = [RDI, RSI, RDX, RCX, R8, R9]

mkFunc :: ([Register] -> [Instr]) -> [Instr]
mkFunc f = f funcRegs ++ [Ret]

callFunc :: String -> [Oper] -> (Register -> [Instr]) -> [Instr]
callFunc fname opers andThen = catMaybes (zipWith maybeMov opers funcRegs)
  ++ [Call (RGG fname)] ++ andThen RAX
  where
  maybeMov (Reg r) r' | r == r' = Nothing
  maybeMov o r = Just (mov o (Reg r))

printf :: [Instr]
printf = [ clear (Reg RAX), Call (RGG "printf") ]

intio :: [CDecl]
intio = 
  [ Label "out_int" $ mkFunc $ \(x:_) ->
    [ mov (Reg x) (Reg RSI)
    , mov (Global "int.Format") (Reg RDI) ]
    ++ printf
  , Label "int.Format"
    [ Asciz "%ld" ]
  , Label "in_int" $ mkFunc $ \_ ->
    callFunc "malloc" [Imm 8] $ \addr -> 
      [ push (Reg addr)
      , mov (Reg addr) (Reg RSI)
      , mov (Global "int.Format") (Reg RDI)
      , clear (Reg RAX)
      , Call (RGG "scanf")
      , pop (Reg RAX)
      , mov (Mem 0 RAX) (Reg RAX)
      ]
  ]

outstring :: CDecl
outstring = Label "out_string" (printf ++ [Ret])

arrayOps :: [CDecl]
arrayOps =
  [ Label "set" $ ($ funcRegs) $ \(arr : pos : val : _) -> 
    offset pos arr ++
    [ mov (Reg val) (Mem 0 arr)
    , Jump "jmp" (RGG "Unit") ]
  , Label "get" $ mkFunc $ \(arr : pos : _) ->
    offset pos arr ++ [ mov (Mem 0 arr) (Reg RAX) ]
  , Label "makeArray" $ mkFunc $ \(size : defVal : _) -> 
    [ push (Reg size)
    , push (Reg defVal)
    , imul (Imm 8) (Reg size) ]
    ++ callFunc "malloc" [Reg size] (\arr -> 
       [pop (Reg R13), pop (Reg R12), push (Reg arr)] ++ 
       callFunc "setAll" [Reg arr, Reg R12, Reg R13] (\_ -> 
         [pop (Reg RAX)]))
  ]
  where
  offset pos arr = 
    [ mov (Reg pos) (Reg R12)
    , imul (Imm 8) (Reg R12)
    , add (Reg R12) (Reg arr) ]

    

errorDecls :: [CDecl]
errorDecls = [ Label "error" $
  [ mov (Reg RDI) (Reg RSI)
  , mov (Global "error.msg") (Reg RDI)
  ] ++ printf ++ 
  [ mov (Imm 60) (Reg RAX)
  , clear (Reg RDI)
  , Syscall
  ]
  , Label "error.msg" [ Asciz "Error: %s\\n" ]
  ]

primOps :: [CDecl]
primOps = outstring : divOp : intio ++ intOps 
  ++ cmpOps ++ arrayOps ++ errorDecls

compileDecl :: Decl -> [CDecl]
compileDecl d = case d of
  DataDecl _ (DataDefn _ alts) ->
    [ l | DataAlt name args <- alts, l <- constructor name (length args) ]
  FuncDecl fname funcDefn -> func fname funcDefn

toSymbolName :: String -> String
toSymbolName = concatMap f where
  f '\'' = ".P"
  f x = [x]
