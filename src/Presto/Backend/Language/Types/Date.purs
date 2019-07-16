{-
 Copyright (c) 2012-2017 "JUSPAY Technologies"
 JUSPAY Technologies Pvt. Ltd. [https://www.juspay.in]
 This file is part of JUSPAY Platform.
 JUSPAY Platform is free software: you can redistribute it and/or modify
 it for only educational purposes under the terms of the GNU Affero General
 Public License (GNU AGPL) as published by the Free Software Foundation,
 either version 3 of the License, or (at your option) any later version.
 For Enterprise/Commerical licenses, contact <info@juspay.in>.
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  The end user will
 be liable for all damages without limitation, which is caused by the
 ABUSE of the LICENSED SOFTWARE and shall INDEMNIFY JUSPAY for such
 damages, claims, cost, including reasonable attorney fee claimed on Juspay.
 The end user has NO right to claim any indemnification based on its use
 of Licensed Software. See the GNU Affero General Public License for more details.
 You should have received a copy of the GNU Affero General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/agpl.html>.
-}

module Presto.Backend.Types.Date where

import Prelude

import Control.Monad.Eff (Eff)
import Data.Foreign (Foreign, ForeignError(..), fail, toForeign)
import Data.Foreign.Class (class Decode, class Encode)
import Data.Function.Uncurried (Fn3, Fn5, runFn3, runFn5)
import Data.Maybe (Maybe(..), maybe)
import Presto.Backend.Runtime.Common (jsonStringify)

foreign import data Date :: Type
foreign import _getCurrentDate :: forall e. Eff e Date
foreign import _dateToString :: Date -> String
foreign import _compareDate :: Fn5 Date Date Ordering Ordering Ordering Ordering
foreign import _stringToDate :: forall a. Fn3 (a -> Maybe a) (Maybe a) Foreign (Maybe Date)
foreign import _dateStringWithDaysOffset :: forall e. Date -> Int -> (Eff e Date)
foreign import _isAheadOfCurrentDate :: forall e. Date -> (Eff e Boolean)
foreign import _isGivenDateAhead :: forall e. Date -> Date -> (Eff e Boolean)
foreign import _currentDateStringWithSecOffset :: forall e. Int -> (Eff e String)
foreign import _getCurrentDateMillis :: forall e. (Eff e Number)
foreign import _currentDateWithOffset :: forall e. Int -> Eff e Date
foreign import _dateWithCustomOffset :: forall e. Date -> Int -> String -> Eff e Date
foreign import _getDateWithOffset :: forall e. String -> Int -> Eff e String
foreign import _currentDateStringWithoutSpace :: forall e. Eff e String

stringToDate :: Foreign -> Maybe Date
stringToDate = runFn3 _stringToDate Just Nothing

instance decodeDate :: Decode Date where
   decode x = maybe (fail $ ForeignError (jsonStringify x <> " is an invalid date format.")) pure $ stringToDate x

instance encodeDate :: Encode Date where
   encode = toForeign <<< _dateToString

instance showDate :: Show Date where show = _dateToString
instance eqDate :: Eq Date where eq x y = _dateToString x == _dateToString y
instance ordDate :: Ord Date where compare x y = runFn5 _compareDate x y LT EQ GT
