import Control.Monad
import Data.IORef
import System.IO
import Control.Monad.IO.Class

addBinding (var, value) = do
  ref <- newIORef value
  return (var, ref)

sampleBindings = zip ['a'..'e'] [1..5]

-- sampleEnv :: (Char, IORef Integer)
sampleEnv      = do
  refVal <- newIORef 10
  return ('f', refVal)

type Env = IORef [(String, IORef Integer)]

bindVars :: Env -> [(String, Integer)] -> IO Env
bindVars envRef bindings = readIORef envRef >>= extendEnv bindings >>= newIORef
     where extendEnv bindings env = fmap (++ env) (mapM addBinding bindings)
           addBinding (var, value) = do ref <- newIORef value
                                        return (var, ref)

monadTest :: (Num a) => a -> [a]
{- Following two signatures are equivalent -}
-- monadTest val = return val
monadTest val = do return val

eitherTester :: [Int] -> Either String Int
{-Turns out return "!!" does not work; by default return binds to Right.-}
eitherTester []  = Left "!!"
eitherTester [v] = Left $ show v
eitherTester l   = return $ foldr1 (+) l

type Eitherer = Either String Int

mapMer :: (Int -> Int -> Int) -> [Int] -> Eitherer
mapMer op params = mapM unpack params >>= return . (foldr1 op)

unpack :: Int -> Eitherer
unpack n = return n
