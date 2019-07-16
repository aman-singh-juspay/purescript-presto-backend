var moment = require("moment")

exports._getCurrentDate = function () {
  return moment.utc()
}

exports._stringToDate = function(just, nothing, dateString) {
  if (moment(dateString).isValid())
    return just(moment.utc(dateString))
  else
    return nothing
}

exports._dateToString = function(dateUTC) {
  return dateUTC.format('YYYY-MM-DD[T]HH:mm:ss[Z]')
}

exports._compareDate = function(_date1, _date2, _lessThan, _equalsTo, _greaterThan) {
  var date1 = moment(_date1, "YYYY-MM-DD HH:mm:ss")
  var date2 = moment(_date2, "YYYY-MM-DD HH:mm:ss")
  if (date1.isBefore(date2))
    return _lessThan
  else if (date1.isAfter(date2))
    return _greaterThan
  else return _equalsTo
}

exports._dateStringWithDaysOffset = function(date) {
  return function(offset) {
    return function() {
      var newDate = new Date(date)
      return moment(newDate).utc().add(offset,'days')
    }
  }
}

exports._isAheadOfCurrentDate = function(date) {
  return function() {
    var currentDate = new Date()
    var givenDate = new Date(date)
    return (givenDate > currentDate)
  }
}

exports._isGivenDateAhead = function(date) {
  return function (dateToCheckWith) {
    return function() {
      var givenDate = new Date(date)
      var dateToCheck = new Date(dateToCheckWith)
      return (givenDate > dateToCheck)
    }
  }
}


exports._currentDateStringWithSecOffset = function(seconds) {
  return function(){
    return moment.utc().add(seconds,'seconds').format('YYYY-MM-DD[T]HH:mm:ss[Z]')
  }
}

exports._getCurrentDateMillis = function() {
  return Date.now()
}

exports._currentDateWithOffset = function (seconds) {
  return function () {
      return moment.utc().add(seconds, 'seconds')
  }
}

exports._dateWithCustomOffset = function(date) {
  return function(offset) {
    return function(offsetType) {
      return function() {
        var newDate = new Date(date)
        return moment(newDate).utc().add(offset,offsetType)
      }
    }
  }
}

exports._getDateWithOffset = function(date) {
  return function(offset){
    return function(){
      return moment(date).utc().add(offset,'seconds').format('YYYY-MM-DD HH:mm:ss')
    }
  }
}

exports._currentDateStringWithoutSpace = function() {
  return moment.utc().format("YYYYMMDDHHmmss")
}