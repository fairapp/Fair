/**
 Copyright (c) 2022 Marc Prud'hommeaux

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as
 published by the Free Software Foundation, either version 3 of the
 License, or (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#if canImport(TabularData)
import TabularData

/// A `DataFrameProtocol` that can filter itself efficiently.
@available(macOS 12.0, iOS 15.0, *)
public protocol DataSlice {
    /// Returns a selection of rows that satisfy a predicate in the columns you select by name.
    /// - Parameters:
    ///   - columnName: The name of a column.
    ///   - type: The type of the column.
    ///   - isIncluded: A predicate closure that receives an element of the column as its argument
    ///   and returns a Boolean that indicates whether the slice includes the element's row.
    /// - Returns: A data frame slice that contains the rows that satisfy the predicate.
    func filter<T>(on columnName: String, _ type: T.Type, _ isIncluded: (T?) throws -> Bool) rethrows -> DataFrame.Slice

    /// Returns a selection of rows that satisfy a predicate in the columns you select by column identifier.
    /// - Parameters:
    ///   - columnID: The identifier of a column in the data frame.
    ///   - isIncluded: A predicate closure that receives an element of the column as its argument
    ///   and returns a Boolean that indicates whether the slice includes the element's row.
    /// - Returns: A data frame slice that contains the rows that satisfy the predicate.
    func filter<T>(on columnID: ColumnID<T>, _ isIncluded: (T?) throws -> Bool) rethrows -> DataFrame.Slice

    /// Generates a data frame that includes the columns you select with a sequence of names.
    /// - Parameter columnNames: A sequence of column names.
    /// - Returns: A new data frame.
    func selecting<S>(columnNames: S) -> Self where S : Sequence, S.Element == String

    /// Generates a data frame that includes the columns you select with a list of names.
    /// - Parameter columnNames: A comma-separated, or variadic, list of column names.
    /// - Returns: A new data frame.
    func selecting(columnNames: String...) -> Self

    /// Returns a new slice that contains the initial elements of the original slice.
    ///
    /// - Parameter length: The number of elements in the new slice.
    /// The length must be greater than or equal to zero and less than or equal to the number of elements
    /// in the original slice.
    ///
    /// - Returns: A new slice of the underlying data frame.
    func prefix(_ length: Int) -> DataFrame.Slice

    /// Returns a new slice that contains the final elements of the original slice.
    ///
    /// - Parameter length: The number of elements in the new slice.
    /// The length must be greater than or equal to zero and less than or equal to the number of elements
    /// in the original slice.
    ///
    /// - Returns: A new slice of the underlying data frame.
    func suffix(_ length: Int) -> DataFrame.Slice

    var rows: DataFrame.Rows { get }
}

@available(macOS 12.0, iOS 15.0, *)
extension DataFrame : DataSlice { }

@available(macOS 12.0, iOS 15.0, *)
extension DataFrame.Slice : DataSlice { }

@available(macOS 12.0, iOS 15.0, *)
@available(*, deprecated, renamed: "DataSlice")
public typealias FilterableFrame = DataSlice

#endif
