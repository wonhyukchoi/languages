{-# LANGUAGE ExistentialQuantification #-}

import Text.ParserCombinators.Parsec(oneOf, Parser, parse,
                                     skipMany1, space,
                                     many, noneOf, char,
                                     letter, digit, (<|>),
                                     many1,
                                     try, string,
                                     anyChar, alphaNum, notFollowedBy,
                                     sepBy, endBy, ParseError)
import System.Environment(getArgs)
import Control.Monad(liftM, mapM)
import Numeric(readOct, readHex, readFloat)
import Data.Ratio((%), Rational)
import Data.Complex(Complex, Complex((:+)))
import qualified Control.Monad.Except as E
import qualified System.IO as IO
import qualified Data.IORef as IORef
import Control.Monad.IO.Class(liftIO)

main :: IO()
main = do
  args <- getArgs
  if null args then runREPL else (runFile args)

runExpr :: String -> IO()
runExpr expr = primitiveBindings >>= flip evalAndPrint expr

runFile :: [String] -> IO()
runFile args = do
  let fileName = args !! 0
  env <- primitiveBindings 
  runIOThrows $ fmap show $ eval env $ List [Atom "load", String fileName]
  putStrLn $ "Ok, modules loaded: " ++ fileName
  until_ (readPrompt "$~: ") (evalAndPrint env) (== ":q")


runREPL :: IO() 
runREPL = do
  putStrLn "Booting whc Scheme Interpreter... "
  putStrLn "Hello, welcome! "
  baseEnv <- primitiveBindings
  until_ (readPrompt "$~: ") (evalAndPrint baseEnv) (== ":q")

applyProc :: [LispVal] -> IOThrowsError LispVal
applyProc [func, List args] = apply func args
applyProc (func : args)     = apply func args

makePort :: IO.IOMode -> [LispVal] -> IOThrowsError LispVal
makePort mode [String fileName] =
  fmap Port $ liftIO $ IO.openFile fileName mode

closePort :: [LispVal] -> IOThrowsError LispVal
closePort [Port handle] = liftIO $ IO.hClose handle >> 
                          (return $ Bool True)
closePort _             = (return $ Bool False)

readProc :: [LispVal] -> IOThrowsError LispVal
readProc []            = readProc [Port IO.stdin]
readProc [Port handle] = (liftIO $ IO.hGetLine handle) >>= 
                         liftThrows . readExpr

writeProc :: [LispVal] -> IOThrowsError LispVal
writeProc [obj]              = writeProc [obj, Port IO.stdout]
writeProc [obj, Port handle] = liftIO $ IO.hPrint handle obj >> 
                               (return $ Bool True)

readContents :: [LispVal] -> IOThrowsError LispVal
readContents [String fileName] = 
  fmap String $ liftIO $ IO.readFile fileName


load :: String -> IOThrowsError [LispVal]
load fileName = (liftIO $ IO.readFile fileName) >>= 
                liftThrows . readExprList

readAll :: [LispVal] -> IOThrowsError LispVal
readAll [String fileName] = fmap List $ load fileName

type Env = IORef.IORef [(String, IORef.IORef LispVal)]

nullEnv :: IO Env
nullEnv = IORef.newIORef []

type IOThrowsError = E.ExceptT LispError IO

liftThrows :: ThrowsError a -> IOThrowsError a
liftThrows (Left err)  = E.throwError err
liftThrows (Right val) = return val

runIOThrows :: IOThrowsError String -> IO String
runIOThrows action = E.runExceptT (trapError action) >>= return . extractValue

isBound :: Env -> String -> IO Bool
isBound envRef var = do
  thisEnv <- IORef.readIORef envRef
  return $ maybe False (const True) $ lookup var thisEnv

getVar :: Env -> String -> IOThrowsError LispVal
getVar envRef var = do
  env <- liftIO $ IORef.readIORef envRef
  maybe (E.throwError $ UnboundVar "Unbound var" var)
        (liftIO . IORef.readIORef)
        (lookup var env)

setVar :: Env -> String -> LispVal -> IOThrowsError LispVal
setVar envRef var value = do
  env <- liftIO $ IORef.readIORef envRef
  maybe (E.throwError $ UnboundVar "Unbound var" var)
        (liftIO . (flip IORef.writeIORef value))
        (lookup var env)
  return value

defineVar :: Env -> String -> LispVal -> IOThrowsError LispVal
defineVar envRef var value = do
  alreadyDefined <- liftIO $ isBound envRef var
  if alreadyDefined
    then setVar envRef var value >> return value
    else liftIO $ do
      valueRef <- IORef.newIORef value
      env      <- IORef.readIORef envRef
      IORef.writeIORef envRef ((var, valueRef): env)
      return value

bindVars :: Env -> [(String, LispVal)] -> IO Env
bindVars envRef bindings = do
  env   <- IORef.readIORef envRef
  bound <- extendEnv env
  IORef.newIORef bound
  where extendEnv ioEnv = fmap (++ ioEnv) $ mapM addBindings bindings
        addBindings (var, value) = do
          newEnv <- IORef.newIORef value
          return (var, newEnv)

flushStr :: String -> IO ()
flushStr str = putStr str >> IO.hFlush IO.stdout

readPrompt :: String -> IO String
readPrompt prompt = flushStr prompt >> getLine

evalString :: Env -> String -> IO String
evalString env expr = 
  runIOThrows $ fmap show $ (liftThrows $ readExpr expr) >>= eval env

evalAndPrint :: Env -> String -> IO ()
evalAndPrint env expr = evalString env expr >>= putStrLn

until_ :: (Monad m) => m a -> (a -> m()) -> (a->Bool) -> m ()
until_ prompt action isQuit = do
  input <- prompt
  case isQuit input of
    True -> return ()
    _    -> action input >> until_ prompt action isQuit


primitiveBindings :: IO Env
primitiveBindings = nullEnv >>= flip bindVars (primFxns ++ ioFxns)
  where fxnMaker fxnType (name, fxn) = (name, fxnType fxn)
        primFxns                     = map (fxnMaker PrimitiveFunc) primitives
        ioFxns                       = map (fxnMaker IOFunc) ioPrimitives

stringLen :: [LispVal] -> ThrowsError LispVal
stringLen [(String s)] = return $ Number $ fromIntegral $ length s
stringLen [notString]  = E.throwError $ TypeMisMatch "string" notString
stringLen badArgs      = E.throwError $ NumArgs 1 badArgs

stringRef :: [LispVal] -> ThrowsError LispVal
stringRef [(String s), (Number n)]
  | length s < n' + 1  = E.throwError $ Default "Out of bounds"
  | otherwise          = return $ Character $ s !! n'
  where n' = fromIntegral n
stringRef [notS, (Number n)] = E.throwError $ TypeMisMatch "str" notS
stringRef [(String s), notN] = E.throwError $ TypeMisMatch "str" notN
stringRef badArgList         = E.throwError $ NumArgs 2 badArgList


data Unpacker = forall a. Eq a => AnyUnpacker (LispVal -> ThrowsError a)

cond :: Env -> [LispVal] -> IOThrowsError LispVal
cond env [List [condition, value]] = do
  ifTrue <- eval env condition
  case ifTrue of
    Bool True  -> eval env value
    _          -> E.throwError $ NonExhaustive condition
cond env (List [condition, value]:others) = do
  ifTrue <- eval env condition
  case ifTrue of
    Bool True -> eval env value
    _         -> cond env others

caseFxn :: Env -> [LispVal] -> IOThrowsError LispVal
{- Example parsing
(case (* 2 3) ((1 2 3) 1) ((6) 'aa))
List [Atom "*",Number 2,Number 3]
List [List [Number 1,Number 2,Number 3],Number 1]
List [List [Number 6],List [Atom "quote",Atom "aa"]]
-}
caseFxn _ [caseOf] = E.throwError $ NonExhaustive caseOf
caseFxn env (caseOf: first@(List [conds, value]): others) = do
  caseVal <- eval env caseOf
  isCase  <- caseHelper env caseVal first
  case isCase of
    Bool True -> eval env value
    _         -> caseFxn env (caseOf:others)
caseFxn _ badForm = E.throwError $ BadSpecialForm "Syntax Error" $ badForm !! 0

caseHelper :: Env -> LispVal -> LispVal -> IOThrowsError LispVal
caseHelper env caseVal (List [List conds, value]) = do
  condVals <- mapM (eval env) conds
  isEq     <- liftThrows $ mapM (\x-> eqv [caseVal, x]) condVals
  let isCond     = any (\(Bool x) -> x) isEq
  return $ Bool isCond
caseHelper _ badForm _ = E.throwError $ BadSpecialForm "Syntax Error" badForm

equal :: [LispVal] -> ThrowsError LispVal
equal [List xAll@(x:xs), List yAll@(y:ys)] = do
  headVal <- equal [x,y]
  tailVal <- equal [(List xs), (List ys)]
  return $ Bool $ (length xAll == length yAll)  &&
                  (let (Bool x) = headVal in x) &&
                  (let (Bool y) = tailVal in y)
equal [(DottedList xs x), (DottedList ys y)] = equal [List (x:xs), List (y:ys)]
equal [arg1, arg2] = do
  primitiveList <- mapM (unpackEq arg1 arg2)
                        [AnyUnpacker unpackNum, AnyUnpacker unpackStr,
                         AnyUnpacker unpackBool]
  primitiveTrue <- return $ or primitiveList
  eqvTrue <- eqv [arg1, arg2]
  return $ Bool $ (primitiveTrue || let (Bool x) = eqvTrue in x)
equal badArgList = E.throwError $ NumArgs 2 badArgList


unpackEq :: LispVal -> LispVal -> Unpacker -> ThrowsError Bool
unpackEq arg1 arg2 (AnyUnpacker unpackFxn) = do
  arg1UnPacked <- unpackFxn arg1
  arg2UnPacked <- unpackFxn arg2
  return $ arg1UnPacked == arg2UnPacked
  `E.catchError` (const $ return False)


car :: [LispVal] -> ThrowsError LispVal
car [List (x:_)]           = return x
car [DottedList (x:_) _]   = return x
car [badArg]               = E.throwError $ TypeMisMatch "pair" badArg
car badArg                 = E.throwError $ NumArgs 1 badArg

cdr :: [LispVal] -> ThrowsError LispVal
cdr [List (_:xs)]          = return $ List xs
cdr [DottedList [_] x]     = return x
cdr [DottedList (_:xs) x]  = return $ DottedList xs x
cdr [badArg]               = E.throwError $ TypeMisMatch "pair" badArg
cdr badArg                 = E.throwError $ NumArgs 1 badArg

cons :: [LispVal] -> ThrowsError LispVal
cons [x1, List []]            = return $ List [x1]
cons [x, List xs]             = return $ List $ x:xs
cons [x, DottedList xs xlast] = return $ DottedList (x:xs) xlast
cons [x1, x2]                 = return $ DottedList [x1] x2
cons badArgList               = E.throwError $ NumArgs 2 badArgList

eqv :: [LispVal] -> ThrowsError LispVal
eqv [(Bool arg1), (Bool arg2)]             = return $ Bool $ arg1 == arg2
eqv [(Number arg1), (Number arg2)]         = return $ Bool $ arg1 == arg2
eqv [(String arg1), (String arg2)]         = return $ Bool $ arg1 == arg2
eqv [(Atom arg1), (Atom arg2)]             = return $ Bool $ arg1 == arg2
eqv [(DottedList xs x), (DottedList ys y)] = eqv [List $ x:xs, List $ y:ys]
eqv [(List arg1), (List arg2)]             =
  let lenEq = (length arg1) == (length arg2)
      elemEq = all eqvPair $ zip arg1 arg2
      eqvPair (x1, x2) = case eqv [x1, x2] of
        Left err -> False
        Right (Bool val) -> val
  in return $ Bool $ lenEq && elemEq
eqv [_ , _]                                = return $ Bool False
eqv badArgList                             = E.throwError $ NumArgs 2 badArgList


data LispError = NumArgs Integer [LispVal]
                 | TypeMisMatch String LispVal
                 | Parser ParseError
                 | BadSpecialForm String LispVal
                 | NotFunction String String
                 | UnboundVar String String
                 | NonExhaustive LispVal
                 | Default String

showError :: LispError -> String
showError (UnboundVar message varname)   = message ++ " : " ++ varname
showError (BadSpecialForm message form)  = message ++ " : " ++ show form
showError (NotFunction message func)     = message ++ " : " ++ show func
showError (NumArgs expected found)       = "Expected " ++ show expected
                                           ++ " args, but found values "
                                           ++ listShower found
showError (Parser parseErr)              = "Parse error: " ++ show parseErr
showError (TypeMisMatch expected found)  = "Expected type " ++ show expected
                                            ++ " but found " ++ show found
showError (NonExhaustive found)          = "Non-exhaustive pattern $~: "
                                           ++ show found
showError (Default message)              = message

instance Show LispError where
  show = showError

type ThrowsError = Either LispError

trapError :: (E.MonadError a m, Show a) => m String -> m String
trapError action = E.catchError action (return . show)

extractValue :: ThrowsError String -> String
extractValue (Right val) = val

readOrThrow :: Parser a -> String -> ThrowsError a
readOrThrow parser input = case parse parser "" input of
  Left err  -> E.throwError $ Parser err 
  Right val -> return val

readExpr :: String -> ThrowsError LispVal
readExpr = readOrThrow parseExpr

readExprList :: String -> ThrowsError [LispVal]
readExprList = readOrThrow (endBy parseExpr spaces)

baseFxn :: Maybe String -> Env -> [LispVal] -> [LispVal] -> 
  IOThrowsError LispVal
baseFxn varargs env params body = 
  return $ Func (map showVal params) varargs body env

normalFxn :: Env -> [LispVal] -> [LispVal] -> IOThrowsError LispVal
normalFxn = baseFxn Nothing

varArgFxn :: LispVal -> Env -> [LispVal] -> [LispVal] -> 
  IOThrowsError LispVal
varArgFxn = baseFxn . Just . showVal


eval :: Env -> LispVal -> IOThrowsError LispVal
eval env (Atom varName) = getVar env varName
eval env val@(String _) = return val
eval env val@(Bool _) = return val
eval env val@(Number _) = return val
eval env (List [Atom "quote", val]) = return val
eval env (List [Atom "if", condition, ifTrue, ifFalse]) = do
  result <- eval env condition
  case result of
    Bool True  -> eval env ifTrue
    Bool False -> eval env ifFalse
    otherwise  -> E.throwError $ TypeMisMatch "should eval to bool" condition
eval env (List (Atom "cond": condParen)) = cond env condParen
eval env (List (Atom "case": casing))    = caseFxn env casing
eval env (List [Atom "define", Atom var, value]) = 
  eval env value >>= defineVar env var 
eval env (List [Atom "set!", Atom var, value])   = 
  eval env value >>= setVar env var 
eval env (List (Atom "define" : List (Atom var : params) : body)) = 
  normalFxn env params body >>= defineVar env var
eval env (List (Atom "define" : DottedList (Atom var : params) varargs : body)) = 
  varArgFxn varargs env params body >>= defineVar env var
eval env (List (Atom "lambda" : List params : body )) =
  normalFxn env params body
eval env (List (Atom "lambda" : DottedList params varargs : body )) =
  varArgFxn varargs env params body
eval env (List (Atom "lambda" : varargs:(Atom _) : body)) = 
  varArgFxn varargs env [] body
eval env (List [Atom "load", String fileName]) = 
  load fileName >>= fmap last . mapM (eval env)
eval env (List (func@(Atom _): args)) = do
  argsEvaled <- mapM (eval env) args
  funcEvaled <- eval env func
  apply funcEvaled argsEvaled
eval _ badForm = E.throwError $ BadSpecialForm "Syntax Error." badForm


apply :: LispVal -> [LispVal] -> IOThrowsError LispVal
apply (PrimitiveFunc func) args = liftThrows $ func args
apply (Func params varags body closure) args = 
  if len params /= len args && varags == Nothing 
    then E.throwError $ NumArgs (len params) args
    else (liftIO $ bindVars closure $ zip params args) >>= 
         bindVarArgs >>= evalBody
  where 
    len = toInteger . length
    starArgs = drop (length params) args
    bindVarArgs env = 
      case varags of
        Nothing      -> return env
        Just argName -> liftIO $ bindVars env [(argName, List $ starArgs)]
    evalBody env = fmap last $ mapM (eval env) body
apply (IOFunc func) args = func args 

isBool :: LispVal -> Bool
isBool (Bool _) = True
isBool _ = False

ioPrimitives :: [(String, [LispVal] -> IOThrowsError LispVal)]
ioPrimitives = [("apply", applyProc),
                ("open-input-file", makePort IO.ReadMode),
                ("open-output-file", makePort IO.WriteMode),
                ("close-input-port", closePort),
                ("close-output-port", closePort),
                ("read", readProc),
                ("write", writeProc),
                ("read-contents", readContents),
                ("read-all", readAll)]

primitives :: [(String, [LispVal] -> ThrowsError LispVal)]
primitives = [("+", numericBinop (+)),
              ("-", numericBinop (-)),
              ("*", numericBinop (*)),
              ("/", numericBinop div),
              ("quotient", numericBinop quot),
              ("remainder", numericBinop rem),
              ("symbol?", unaryOp symbolp),
              ("number?", unaryOp numberp),
              ("symbol->string", unaryOp sym2str),
              ("string->symbol", unaryOp str2sym),
              ("=", numBoolBinop (==)),
              ("<", numBoolBinop (<)),
              (">", numBoolBinop (>)),
              ("/=", numBoolBinop (/=)),
              (">=", numBoolBinop (>=)),
              ("<=", numBoolBinop (<=)),
              ("&&", boolBoolBinop (&&)),
              ("||", boolBoolBinop (||)),
              ("string=?", strBoolBinop (==)),
              ("string<?", strBoolBinop (<)),
              ("string>?", strBoolBinop (>)),
              ("string<=?", strBoolBinop (<=)),
              ("string>=?", strBoolBinop (>=)),
              ("car", car),
              ("cdr", cdr),
              ("cons", cons),
              ("eq?", eqv),
              ("eqv?", eqv),
              ("equal?", equal),
              ("string-length", stringLen),
              ("string-ref", stringRef)
              ]

numBoolBinop :: (Integer -> Integer -> Bool) ->
                [LispVal] -> ThrowsError LispVal
numBoolBinop = boolBinop unpackNum

boolBoolBinop :: (Bool -> Bool -> Bool) ->
                 [LispVal] -> ThrowsError LispVal
boolBoolBinop = boolBinop unpackBool

strBoolBinop :: (String -> String -> Bool) ->
                [LispVal] -> ThrowsError LispVal
strBoolBinop = boolBinop unpackStr

boolBinop :: (Eq a) => (LispVal -> ThrowsError a) ->
                       (a->a->Bool) ->
                       [LispVal] -> ThrowsError LispVal
boolBinop unpacker funct params = if length params /= 2
                                  then E.throwError $ NumArgs 2 params
                                  else do
                                    lhs <- unpacker $ params !! 0
                                    rhs <- unpacker $ params !! 1
                                    return $ Bool $ funct lhs rhs

unpackBool :: LispVal -> ThrowsError Bool
unpackBool (Bool n) = return n
unpackBool (String s) = let parsed = reads s :: [(Bool, String)] in
                         if null parsed
                           then E.throwError $ TypeMisMatch "boolean" $ String s
                           else return $ fst $ parsed !! 0
unpackBool notBool = E.throwError $ TypeMisMatch "boolean" notBool

unpackStr :: LispVal -> ThrowsError String
unpackStr (String s) = return s
unpackStr (Number s) = return $ show s
unpackStr (Bool s)   = return $ show s
unpackStr notStr     = E.throwError $  TypeMisMatch "string" notStr

unaryOp :: (LispVal -> LispVal) -> [LispVal] -> ThrowsError LispVal
unaryOp f [v] = return $ f v

symbolp, numberp, sym2str, str2sym :: LispVal -> LispVal
symbolp (Atom _) = Bool True
symbolp _        = Bool False
numberp (Number _) = Bool True
numberp _          = Bool False
sym2str (Atom a) = String a
sym2str _        = String ""
str2sym (String s) = Atom s
str2sym _          = Atom ""

numericBinop :: (Integer -> Integer -> Integer) ->
  [LispVal] -> ThrowsError LispVal
numericBinop op []            = Left   $ NumArgs 2 []
numericBinop op singleVal@[_] = Left   $ NumArgs 2 singleVal
numericBinop op params        = mapM unpackNum params >>=
                                return . Number . (foldr1 op)

unpackNum :: LispVal -> ThrowsError Integer
unpackNum (Number n) = return n
unpackNum (String s) = let parsed = reads s :: [(Integer, String)] in
                         if null parsed
                           then E.throwError $ TypeMisMatch "number" $ String s
                           else return $ fst $ parsed !! 0
unpackNum (List [l]) = unpackNum l
unpackNum notNum = E.throwError $ TypeMisMatch "number" notNum

parseTest :: Parser LispVal
parseTest = parseNumber

parseExpr :: Parser LispVal
parseExpr = parseAtom
            <|> parseString
            <|> try parseComplex
            <|> try parseFloat
            <|> try parseRatio
            <|> parseNumber
            <|> parseBool
            <|> parseChar
            <|> parseQuoted
            <|> do char '('
                   x <- try parseList <|> try parseDottedList
                   char ')'
                   return x

data LispVal = Atom String |
               List [LispVal] |
               DottedList [LispVal] LispVal |
               Number Integer |
               String String |
               Bool Bool |
               Character Char |
               Float Double |
               Ratio Rational |
               Complex (Complex Double) |
               PrimitiveFunc ([LispVal] -> ThrowsError LispVal) |
               Func {params :: [String], varag :: (Maybe String),
                     body :: [LispVal], closure :: Env} |
               IOFunc ([LispVal] -> IOThrowsError LispVal) |
               Port IO.Handle

instance Show LispVal where
 show = showVal

showTemp :: LispVal -> String
showTemp (PrimitiveFunc _)                        = show "Primitive Func"
showTemp (Func params varag body closur)          = "params: " ++ show params ++
                                                    "\nvarag: " ++ show varag ++
                                                    "\nbody: "  ++ show body 
showTemp (Atom contents) = "Atom \"" ++ contents ++ "\""
showTemp (String contents) = "\"" ++ contents ++ "\""
showTemp (Number value) = "Number " ++ show value
showTemp (Float value) = show value
showTemp (Ratio value) = show value
showTemp (Character value) = show value
showTemp (Bool True) = "Bool True"
showTemp (Bool False) = "Bool False"
showTemp (List contents) = "List " ++ show contents
showTemp (DottedList listPart elemPart) = "("
                                         ++ listShowerTemp listPart
                                         ++ "." ++ showTemp elemPart
                                         ++ ")"
showTemp (Port _)   = "<IO Port>"
showTemp (IOFunc _) = "<IO primitive>"


showVal :: LispVal -> String
showVal (Atom contents) = contents
showVal (String contents) = "\"" ++ contents ++ "\""
showVal (Number value) = show value
showVal (Float value) = show value
showVal (Ratio value) = show value
showVal (Character value) = show value
showVal (Bool True) = "#t"
showVal (Bool False) = "#f"
showVal (List contents) = "(" ++ listShower contents ++ ")"
showVal (DottedList listPart elemPart) = "("
                                         ++ listShower listPart
                                         ++ "." ++ showVal elemPart
                                         ++ ")"
showVal (PrimitiveFunc _) = "<primitive>"
showVal (Func {params=args, varag=varags, body=body, closure=env}) = 
  "(lambda (" ++ unwords (map show args) ++
    (case varags of
      Nothing -> ""
      Just starArg -> " . " ++ starArg) ++ ") ...)"
showVal (Port _)   = "<IO Port>"
showVal (IOFunc _) = "<IO primitive>"


listShowerTemp :: [LispVal] -> String
listShowerTemp = unwords . (map showTemp)

listShower :: [LispVal] -> String
listShower = unwords . (map showVal)

parseNumber :: Parser LispVal
parseNumber = parseDecimal1
              <|> parseDecimal2
              <|> parseHex
              <|> parseOct
              <|> parseBin

parseList :: Parser LispVal
parseList = liftM List $ sepBy parseExpr spaces

parseDottedList :: Parser LispVal
parseDottedList = do
  head <- endBy parseExpr spaces
  tail <- char '.' >> spaces >> parseExpr
  return $ DottedList head tail

parseQuoted :: Parser LispVal
parseQuoted = do
  char '\''
  x <- parseExpr
  return $ List [Atom "quote", x]

parseChar :: Parser LispVal
parseChar = do
  try $ string "#\\"
  val <- try (string "space" <|> string "newline")
        <|> do {x <- anyChar; notFollowedBy alphaNum; return [x]}
  return $ Character $ case val of
    "space" -> ' '
    "newline" -> '\n'
    x -> head x


parseFloat :: Parser LispVal
parseFloat = do
  base <- many1 digit
  char '.'
  fractional <- many1 digit
  let floatVal = read base ++ "." ++ read fractional
      takeFloat = fst . head . readFloat
  (return . Float . takeFloat) floatVal

parseRatio :: Parser LispVal
parseRatio = do
  numerator <- many1 digit
  char '/'
  denominator <- many1 digit
  let ratioVal = (read numerator) % (read denominator)
  return $ Ratio ratioVal

parseComplex:: Parser LispVal
parseComplex = do
  realPart <- many1(digit)
  char '+'
  imagPart <- many1(digit)
  char 'i'
  let complexVal = read realPart :+ read imagPart
  return $ Complex complexVal

parseDecimal1 :: Parser LispVal
parseDecimal1 = liftM (Number . read) $ many1 digit

parseDecimal2 :: Parser LispVal
parseDecimal2 = do
  try $ string "#d"
  x <- many1(digit)
  return . Number . read $ x

parseBin :: Parser LispVal
parseBin = do
  try $ string "#b"
  x <- many1(oneOf "10")
  (return . Number . takeBinHelper) x

takeBinHelper :: String -> Integer
takeBinHelper = takeBin 0

takeBin :: Integer -> String -> Integer
takeBin prevVal "" = prevVal
takeBin prevVal (x:xs) =
  let newVal = read [x]
      accVal = prevVal * 2 + newVal
  in takeBin accVal xs

parseHex :: Parser LispVal
parseHex = do
  try $ string "#x"
  x <- many1(oneOf "0123456789abcdef")
  (return . Number . takeHex) x
  where takeHex = fst . head . readHex


parseOct :: Parser LispVal
parseOct = do
  try $ string "#o"
  x <- many1(oneOf "01234567")
  (return . Number . takeOct) x
  where takeOct = fst . head . readOct


parseAtom :: Parser LispVal
parseAtom = do
  first <- letter <|> symbol
  second <- many (letter <|> digit <|> symbol)
  let atom = first:second
  return $ case atom of
    _    -> Atom atom

parseString :: Parser LispVal
parseString = do
                char '"'
                x <- many (noneOf "\"")
                char '"'
                return $ String x

parseBool :: Parser LispVal
parseBool = do
  char '#'
  (char 't' >> return (Bool True)) <|> (char 'f' >> return (Bool False))

spaces :: Parser ()
spaces = skipMany1 space

symbol :: Parser Char
symbol = oneOf "!$%&|*+-/:<=>?@^_~"
