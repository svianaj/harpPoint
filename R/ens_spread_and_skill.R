#' Compute the skill (RMSE) and spread of an ensemble forecast
#'
#' The ensemble mean and spread are computed as columns in a \code{harp_fcst}
#' object. Typically the scores are aggregated over lead time by other grouping
#' variables cam be chosen. The mean bias is also computed.
#'
#' @param .fcst A \code{harp_fcst} object with tables that have a column for
#'   observations, or a single forecast table.
#' @param parameter The name of the column for the observed data.
#' @param groupings The groups for which to compute the ensemble mean and
#'   spread. See \link[dplyr]{group_by} for more information of how grouping
#'   works.
#' @param spread_drop_member Which members to drop for the calculation of the
#'   ensemble variance and standard deviation. For harp_fcst objects, this can
#'   be a numeric scalar - in which case it is recycled for all forecast models;
#'   a list or numeric vector of the same length as the harp_fcst object, or a
#'   named list with the names corresponding to names in the harp_fcst object.
#' @param jitter_fcst A function to perturb the forecast values by. This is used
#'   to account for observation error in the spread. For other statistics it is
#'   likely to make little difference since it is expected that the observations
#'   will have a mean error of zero.
#' @param ... Not used.
#'
#' @return An object of the same format as the inputs but with data grouped for
#'   the \code{groupings} column(s) and columns for \code{rmse}, \code{spread}
#'   and \code{mean_bias}.
#' @export
#'
#' @examples
ens_spread_and_skill <- function(
  .fcst, parameter, groupings = "leadtime", spread_drop_member = NULL,
  jitter_fcst = NULL, ...
) {
  UseMethod("ens_spread_and_skill")
}

#' @export
ens_spread_and_skill.default <- function(
  .fcst, parameter, groupings = "leadtime", spread_drop_member = NULL,
  jitter_fcst = NULL, ...
) {

  if (!is.list(groupings)) {
    groupings <- list(groupings)
  }

  if (!is.null(spread_drop_member)) {
    if (!is.numeric(spread_drop_member)) {
      stop("`spread_drop_member` must be numeric.", call. = FALSE)
    }
  }

  col_names  <- colnames(.fcst)
  parameter  <- rlang::enquo(parameter)
  chr_param  <- rlang::quo_name(parameter)
  if (length(grep(chr_param, col_names)) < 1) {
    stop(paste("No column found for", chr_param), call. = FALSE)
  }

  if (is.function(jitter_fcst)) {
    .fcst <- dplyr::mutate_at(
      .fcst,
      dplyr::vars(dplyr::contains("_mbr")),
      ~purrr::map_dbl(., jitter_fcst)
    )
  }

  ens_mean <- "ss_mean"
  ens_var  <- "ss_var"

  .fcst <- harpIO::ens_mean_and_var(
    .fcst, mean_name = ens_mean, var_name = ens_var,
    var_drop_member = spread_drop_member
  )

  compute_spread_skill <- function(compute_group, fcst_df) {

    if (!any(grepl("dropped_members", colnames(fcst_df)))) {
      fcst_df[[paste0("dropped_members_", ens_var)]] <- fcst_df[[ens_var]]
    }

    if (length(compute_group) == 1 && compute_group == "threshold") {
      grouped_fcst <- fcst_df
    } else {
      compute_group <- rlang::syms(compute_group[compute_group != "threshold"])
      grouped_fcst  <- dplyr::group_by(fcst_df, !!! compute_group)
    }

    grouped_fcst %>%
      dplyr::summarise(
        num_cases              = dplyr::n(),
        mean_bias              = mean(.data[[ens_mean]] - !!parameter),
        stde                   = stats::sd(.data[[ens_mean]] - !!parameter),
        rmse                   = sqrt(mean((.data[[ens_mean]] - !!parameter) ^ 2)),
        spread                 = sqrt(mean(.data[[ens_var]])),
        dropped_members_spread = sqrt(mean(.data[[paste0("dropped_members_", ens_var)]]))
      ) %>%
      dplyr::mutate(
        spread_skill_ratio                 = .data[["spread"]] / .data[["rmse"]],
        dropped_members_spread_skill_ratio = .data[["dropped_members_spread"]] / .data[["rmse"]]
      )
  }

  purrr::map_dfr(groupings, compute_spread_skill, .fcst) %>%
    fill_group_na(groupings)

}

#' @export
ens_spread_and_skill.harp_fcst <- function(
  .fcst, parameter, groupings = "leadtime", spread_drop_member = NULL,
  jitter_fcst = NULL, ...
) {

  parameter   <- rlang::enquo(parameter)
  if (!inherits(try(rlang::eval_tidy(parameter), silent = TRUE), "try-error")) {
    if (is.character(rlang::eval_tidy(parameter))) {
      parameter <- rlang::eval_tidy(parameter)
      parameter <- rlang::ensym(parameter)
    }
  }

  spread_drop_member <- parse_member_drop(spread_drop_member, names(.fcst))

  list(
    ens_summary_scores = purrr::map2(
      .fcst, spread_drop_member,
      ~ens_spread_and_skill(.x, !! parameter, groupings, .y, jitter_fcst)
    ) %>%
      dplyr::bind_rows(.id = "mname"),
    ens_threshold_scores = NULL
  ) %>%
    add_attributes(.fcst, !! parameter)

}

parse_member_drop <- function(x, nm) {

  if (!is.null(names(x))) {
    x <- as.list(x)
  }

  if (!is.list(x)) {
    if (is.null(x)) {
      return(sapply(nm, function(x) NULL, simplify = FALSE))
    }
    if (length(x) == 1) {
      return(sapply(nm, function(.x) x, simplify = FALSE))
    }
    if (length(x) == length(nm)) {
      x <- as.list(x)
      names(x) <- nm
      return(x)
    }
    stop("Bad input for `spread_exclude_member`", call. = FALSE)
  }

  if (is.null(names(x))) {

    if (length(x) == length(nm)) {
      names(x) <- nm
      return(x)
    }

    stop(
      "If `spread_exclude_member` is a list ",
      "it must be the same length as `.fcst` or have names",
      call. = FALSE
    )

  }

  if (identical(sort(names(x)), sort(nm))) {
    return(x[nm])
  }

  if (length(intersect(names(x), nm)) < 1) {
    stop(
      "spread_exclude_member: ",
      paste(names(x), collapse = ", "),
      " not found in `.fcst`.",
      call. = FALSE
    )
  }

  if (length(setdiff(names(x), nm)) > 0) {
    stop(
      "spread_exclude_member: ",
      paste(setdiff(names(x), nm), collapse = ", "),
      " not found in `.fcst`.",
      call. = FALSE
    )
  }

  x <- c(x, sapply(setdiff(nm, names(x)), function(x) NULL, simplify = FALSE))

  x[nm]

}


